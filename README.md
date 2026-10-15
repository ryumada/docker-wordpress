# Dockerized WordPress Stack with Nginx and MySQL

This repository provides a robust and secure starting point for a WordPress environment using Docker Compose. It's designed to be flexible for both development and production use cases, offering multiple configurations for Nginx to work with different WordPress Docker images.

The stack includes:
- **WordPress:** The application itself.
- **MySQL:** The database server.
- **Nginx:** A high-performance web server acting as a reverse proxy or a web server, depending on the WordPress image used.

---

## Features

- **Quick Setup:** Uses Docker Compose for a simple, single-command deployment.
- **Secure Password Handling:** Implements Docker secrets to keep your database password out of plain text configuration files.
- **Two Nginx Configurations:** Provides two pre-configured Nginx server blocks to handle both Apache and FPM-based WordPress images.
- **Security-Focused Scripts:** Includes helper scripts to set up a secure Nginx `default-deny` block and generate a Diffie-Hellman key for enhanced SSL security.
- **Customizable PHP:** Easily extend the PHP configuration with a custom `.ini` file.

---

## Prerequisites

To get started, you must have the following installed on your system:
- **Docker**
- **Docker Compose**

---

## Getting Started

Follow these steps to set up and run the WordPress stack.

### Step 1: Configure Environment Variables

Create a `.env` file by copying the example and filling in the details.

```bash
cp .env.example .env
```

Edit the newly created `.env` file and set the values for:
- `WORDPRESS_IMAGE_TAG`: Choose between an Apache-based image (`6.8.2-php8.4-apache`) or an FPM-based image (`6.8.2-php8.4-fpm`).
- `WORDPRESS_PORT`: The port on your host machine where WordPress will be accessible (e.g., `8080`).
- `WORDPRESS_DB_NAME` and `WORDPRESS_DB_USER`: Your preferred database name and user.

### Step 2: Set the Database Password

For security, this setup uses a Docker secret to manage the database password.

Create the secret file:
```bash
cp .secrets/db_password.example .secrets/db_password
```
Now, edit the `db_password` file and replace `enter_your_db_password` with a strong password. **Do not add this file to your version control.**

### Step 3: Run the Containers

With your configuration files ready, start the services using Docker Compose:

```bash
docker-compose up -d
```
The `-d` flag runs the containers in detached mode.

### Important: Port Mapping in `docker-compose.yml`

The `docker-compose.yml` file is configured to work with either the `apache` or `fpm` WordPress images, but you must manually uncomment the correct port mapping.

- For the `apache` image: Use `- ${WORDPRESS_PORT}:80`. This maps the host port to Apache's default port inside the container.
- For the `fpm` image: Use `- ${WORDPRESS_PORT}:9000`. This maps the host port to the PHP-FPM service's default port, which requires a separate web server (like Nginx on your host machine) to forward requests.

### Example docker-compose.yml ports section:

```docker
# The port mapping depends on the image you choose in the .env file.
ports:
  # For the 'apache' image, uncomment the line below.
  # - ${WORDPRESS_PORT}:80
  # For the 'fpm' image, uncomment the line below.
  - ${WORDPRESS_PORT}:9000
```

### Consistent Volume Mounts for Both Images

A key benefit of this setup is that the volume mounts for your files remain the same, regardless of whether you're using the Apache or FPM image.

- **Custom PHP Configuration**: The `php-config/custom.ini` file is always mounted to `/usr/local/etc/php/conf.d/custom.ini` inside the container. Both Apache and FPM images are configured to automatically load `.ini` files from this location, so your custom PHP settings will always be applied.

- **WordPress Files**: The core WordPress files, including your themes, plugins, and uploads, are consistently located at `/var/www/html` inside the container. The `docker-compose.yml` file mounts your local `./wordpress` directory to this location.

- **Database Files**: The MySQL database files are consistently located at `/var/lib/mysql` inside the container. The `docker-compose.yml` file now mounts your local `./data/db` directory to this location.

This consistency makes switching between image types simple and seamless.

### Step 4: Configure Nginx (Optional but Recommended)

If you are using Nginx on the host machine to serve your site, you will need to apply one of the provided Nginx configuration files.

First, secure your Nginx server by running the included scripts. These require `sudo` privileges.

```bash
# Set up a secure default-deny block
sudo ./scripts/install_nginx_default_deny.sh

# Generate a Diffie-Hellman key for enhanced SSL security
sudo ./scripts/install_ssl_dhparams_key.sh
```

Next, copy the appropriate configuration file to your Nginx `sites-available` directory.

- **For `WORDPRESS_IMAGE_TAG=...-fpm`:**
  - Copy `nginx_sites_available_configurations/nginx_as_webserver-fpm_image` to `/etc/nginx/sites-available/your_domain.com.conf`.
- **For `WORDPRESS_IMAGE_TAG=...-apache`:**
  - Copy `nginx_sites_available_configurations/nginx_as_proxy-apache_image` to `/etc/nginx/sites-available/your_domain.com.conf`.

Remember to replace `enter_your_domain` and `enter_wordpress_port` with your actual domain and port number in the copied file.

Finally, enable the site, test the Nginx configuration, and reload the service:
```bash
sudo ln -s /etc/nginx/sites-available/your_domain.com.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

---

## Customizing WordPress

### Environment Constants

You can add custom PHP `define` statements to your `wp-config.php` file using the `WORDPRESS_CONFIG_EXTRA` variable in your `.env` file. This is useful for setting constants like `WP_HOME`, `WP_SITEURL`, or toggling debug settings.

Example for setting site URLs:
```bash
WORDPRESS_CONFIG_EXTRA="define('WP_HOME', 'https://example.com/blog'); define('WP_SITEURL', 'https://example.com/blog');"
```

### Customizing PHP

The `php-config/custom.ini.example` file shows how to easily customize PHP settings like `upload_max_filesize` and `memory_limit`. The `docker-compose.yml` file already mounts this directory, so any changes you make to `php-config/custom.ini` will be applied to the WordPress container upon restart.

---

---

## Backup & Snapshot Utilities

This deployment includes a full suite of backup, restore, and snapshot utilities modeled after the enterprise-grade backup architecture from `docker-odoo`.

- **Full Deployment Snapshot (`scripts/snapshot-docker-wordpress.sh`)**: Creates a complete compressed `.tar.zst` archive including MySQL database dump, `data/wordpress` files, `.env`, `.secrets`, `docker-compose.yml`, PHP and Nginx configurations, metadata (`manifest.json`), and git commit hashes.
- **Focused Data Backup (`scripts/backupdata-docker-wordpress.sh`)**: Fast zip archive containing MySQL database dump and `data/wordpress`.
- **Snapshot & Data Restoration (`scripts/restore-snapshot.sh` & `scripts/restore_backupdata-docker-wordpress.sh`)**: Fast `--data-only` restore or full environment rollback with container coordination.
- **Google Drive & Cloud Storage Integration**: Direct upload and retention management (`list-snapshot.sh`, `download-snapshot.sh`, `upload-snapshot.sh`, `cleanup-snapshot.sh`, `upload-temp-snapshots.sh`).
- **Secondary VPS Remote Offloading**: Push backups offsite using passwordless SSH keys (`generate-snapshot-ssh-key.sh`).
- **Automated Cron & Logrotate**: Scheduled backups with system-wide symlinks (`/usr/local/sbin/snapshot-docker-wordpress`).

For detailed documentation, configuration options, and command references, see [scripts/README.md](scripts/README.md).

---

## Scripts

- `update_env_file.sh`: Safely updates your `.env` file from `.env.example` while preserving existing configuration values.
- `install_nginx_default_deny.sh`: Sets up a secure Nginx `default-deny` configuration.
- `install_ssl_dhparams_key.sh`: Generates a Diffie-Hellman key for enhanced SSL security.
- `restore-snapshot.sh`: Restores WordPress deployment snapshots.
- `list-snapshot.sh`, `download-snapshot.sh`, `upload-snapshot.sh`, `cleanup-snapshot.sh`, `upload-temp-snapshots.sh`, `generate-snapshot-ssh-key.sh`: Google Drive and secondary VPS snapshot management tools.
- `scripts/installer/`: Contains automated installers for snapshot, backupdata, restore, and sudoers rules.

---

## File Structure

```
.
├── .env.example
├── .gitignore
├── .secrets/
│   └── db_password.example
├── data/
│   ├── wordpress/
│   └── db/
├── docker-compose.yml
├── LICENSE
├── nginx_sites_available_configurations/
│   ├── nginx_as_proxy-apache_image
│   └── nginx_as_webserver-fpm_image
├── php-config/
│   └── custom.ini.example
└── scripts/
    ├── example/
    │   ├── backupdata.sh.example
    │   ├── restore_backupdata.sh.example
    │   └── snapshot.sh.example
    ├── installer/
    │   ├── install-backupdata.sh
    │   ├── install-restore_backupdata.sh
    │   ├── install-snapshot.sh
    │   ├── install_sudoers.sh
    │   └── uninstall-snapshot.sh
    ├── lib/
    │   ├── ssh_utils.sh
    │   └── wp_utils.sh
    ├── cleanup-snapshot.sh
    ├── download-snapshot.sh
    ├── generate-snapshot-ssh-key.sh
    ├── install_nginx_default_deny.sh
    ├── install_ssl_dhparams_key.sh
    ├── list-snapshot.sh
    ├── README.md
    ├── restore-snapshot.sh
    ├── update_env_file.sh
    ├── upload-snapshot.sh
    └── upload-temp-snapshots.sh
```

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

---

_This README was created by an AI._

Copyright © 2025 ryumada
