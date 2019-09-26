#!/bin/bash
set -euo pipefail

# Remove exec from original entrypoint so we can continue here
sed -i -e 's/exec/\# exec/g' /usr/local/bin/docker-entrypoint.sh

# Normal setup
/bin/bash /usr/local/bin/docker-entrypoint.sh $1

# Generate vars for wp-config.php injection
echo "Generating PHP Defines from ENV..."
DEFINES=$(awk -v pat="$CONFIG_VAR_FLAG" 'END {
  print "// Generated by docker-entrypoint2.sh:";

  for (name in ENVIRON) {
    if ( name ~ pat ) {
      print "define(\"" substr(name, length(pat)+1) "\", \"" ENVIRON[name] "\");"
    }
  }

  print " "
}' < /dev/null)
echo $DEFINES

echo "Adding Defines to wp-config.php..."

# Remove previously-injected vars
sed '/\/\/ENTRYPOINT_START/,/\/\/ENTRYPOINT_END/d' wp-config.php > wp-config.tmp

# Add current vars
awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config.tmp > wp-config.php <<EOF
//ENTRYPOINT_START

$DEFINES

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
  \$_SERVER['HTTPS'] = 'on';
}

//ENTRYPOINT_END

EOF

rm wp-config.tmp

# First-run configuration
if [ ! -f /var/www/firstrun ]; then
  echo "Executing first-run setup..."

  # Install HyperDB Config
  if [ "$ENABLE_HYPERDB" == "true" ]; then
    echo "Installing HyperDB WPDB Drop-in"
    cp /var/www/config/hyperdb/db-config.php /var/www/html/
    cp /var/www/config/hyperdb/db.php /var/www/html/wp-content/
  fi

  # Install $WP_PLUGINS
  echo "Installing WordPress Plugins: $WP_PLUGINS"

  for PLUGIN in $WP_PLUGINS; do
    echo "## Installing $PLUGIN"
    if [ ! -e "wp-content/plugins/$PLUGIN" ]; then
      if ( wget "https://downloads.wordpress.org/plugin/$PLUGIN.zip" ); then
        unzip "$PLUGIN.zip" -q -d /var/www/html/wp-content/plugins/
        rm "$PLUGIN.zip"
      else
        echo "## WARN: wget failed for https://downloads.wordpress.org/plugin/$PLUGIN.zip"
      fi
    else
      echo "### $PLUGIN already installed, skipping."
    fi
  done

  # Print firstrun date/time to file
  date > /var/www/firstrun
else
  echo "First run already completed, skipping configuration."
fi

# Set up Nginx Helper log directory
mkdir -p wp-content/uploads/nginx-helper

# Set usergroup for all modified files
chown -R www-data:www-data /var/www/html/


if [ -n "$CRON_CMD" ]; then
  echo "Installing Cron command: $CRON_CMD"
  #write out current crontab
  crontab -l > mycron
  #echo new cron into cron file
  echo "$CRON_CMD" >> mycron
  #install new cron file
  crontab mycron
  rm mycron
fi

if [ "$ENABLE_CRON" == "true" ]; then
  echo "Starting Cron daemon..."
  crond
fi

exec "$@"