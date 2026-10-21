<?php
// Sanitized example. The real wp-config.php is NOT committed (it holds secrets).
// Real file permissions on the server: owner www-data, mode 640.

define( 'DB_NAME',     'wordpress_db' );
define( 'DB_USER',     'wp_user' );
define( 'DB_PASSWORD', 'CHANGE_ME' );
define( 'DB_HOST',     'localhost' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  '' );

// Generate fresh values at https://api.wordpress.org/secret-key/1.1/salt/
define( 'AUTH_KEY',         'CHANGE_ME' );
define( 'SECURE_AUTH_KEY',  'CHANGE_ME' );
define( 'LOGGED_IN_KEY',    'CHANGE_ME' );
define( 'NONCE_KEY',        'CHANGE_ME' );
define( 'AUTH_SALT',        'CHANGE_ME' );
define( 'SECURE_AUTH_SALT', 'CHANGE_ME' );
define( 'LOGGED_IN_SALT',   'CHANGE_ME' );
define( 'NONCE_SALT',       'CHANGE_ME' );

$table_prefix = 'wp_';
define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
