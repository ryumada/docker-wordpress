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

For the `apache` image: Use `- ${WORDPRESS_PORT}:80`. This maps the host port to Apache's default port inside the container.

For the `fpm` image: Use `- ${WORDPRESS_PORT}:9000`. This maps the host port to the PHP-FPM service's default port, which requires a separate web server (like Nginx on your host machine) to forward requests.

### Example docker-compose.yml ports section:

```docker
    # The port mapping depends on the image you choose in the .env file.
    ports:
      # For the 'apache' image, uncomment the line below.
      # - ${WORDPRESS_PORT}:80
      # For the 'fpm' image, uncomment the line below.
      - ${WORDPRESS_PORT}:9000
```

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

## Customizing PHP

The `php-config/custom.ini.example` file shows how to easily customize PHP settings like `upload_max_filesize` and `memory_limit`. The `docker-compose.yml` file already mounts this directory, so any changes you make to `php-config/custom.ini` will be applied to the WordPress container upon restart.

---

## Scripts

`update_env_file.sh`

This script provides a safe and easy way to update your .env file when the .env.example template changes. It works by first backing up your existing .env file to .env.bak, then creating a new .env file from the latest .env.example template, and finally merging all the variables and values from the backup file back into the new one. This ensures you can easily add new environment variables without losing your existing configurations.

---

## File Structure

```
.
├── .env.example
├── .gitignore
├── .secrets/
│   └── db_password.example
├── docker-compose.yml
├── LICENSE
├── nginx_sites_available_configurations/
│   ├── nginx_as_proxy-apache_image
│   └── nginx_as_webserver-fpm_image
├── php-config/
│   └── custom.ini.example
└── scripts/
    ├── install_nginx_default_deny.sh
    └── install_ssl_dhparams_key.sh
```

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

---

_This README was created by an AI._

Copyright © 2025 ryumada
