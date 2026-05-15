By applying **First Principles Thinking**, this SOP is designed around the Principle of Least Privilege: the user is granted exactly the access needed to manage WordPress files (via a Chroot Jail and bind mounts) while completely neutralizing SSH identity bloat and preventing arbitrary shell execution.

---

# Standard Operating Procedure: Secure SFTP User Provisioning

**Objective:** To provision a securely isolated SFTP user (`user-sftp`) capable of modifying WordPress themes and plugins without gaining shell access to the host server or compromising the Docker container's `www-data` permissions.

## Phase 1: User Provisioning

The first step is to create the user entity, explicitly deny it terminal access, and assign it to the web server's group.

1. **Create the user with no shell access:**
    
    ```bash
    sudo useradd -s /usr/sbin/nologin user-sftp
    ```
    
2. **Add the user to the web server group:**
    
    ```bash
    sudo usermod -aG www-data user-sftp
    ```
    
3. **Set the password of the user**
    
    ```bash
    sudo passwd user-sftp
    ```
    

## Phase 2: Chroot Jail Initialization

The SSH daemon requires absolute proof that a jailed user cannot manipulate their own root directory to escape. The jail's root must be owned by the system `root`.

1. **Enforce strict root ownership on the home directory:**
    
    ```bash
    sudo mkdir /home/user-sftp
    sudo chown root:root /home/user-sftp
    ```
    
2. **Apply strict permissions (no group or world write access):**
    
    ```bash
    sudo chmod 755 /home/user-sftp
    ```
    

## Phase 3: Directory Mapping (Bind Mount)

Because the user is locked in `/home/user-sftp`, they cannot navigate to your actual project files. We must securely bridge the Docker data directory into the jail.

1. **Create the mount point inside the jail:**
    
    ```bash
    sudo mkdir -p /home/user-sftp/wordpress
    ```
    
2. **Bind mount the Docker WordPress volume:**
Replace `/path/to/your/project` with the actual absolute path to your Docker repository.
    
    ```bash
    sudo mount --bind /path/to/your/project/data/wordpress /home/user-sftp/wordpress
    ```
    
3. **Persist the mount across reboots:**
Open `/etc/fstab` and append the following line:
    
    ```
    /path/to/your/project/data/wordpress /home/user-sftp/wordpress none bind 0 0
    ```
    

## Phase 4: Permission Architecture

To prevent a compromised WordPress plugin from overwriting core system files, we apply write permissions *only* to the directories that actively require them.

1. **Set baseline ownership to root and the web group:**
    
    ```bash
    sudo chown -R root:www-data /home/user-sftp/wordpress
    ```
    
2. **Lock down the entire WordPress directory (Read-Only for the group):**
    
    ```bash
    sudo find /home/user-sftp/wordpress -type d -exec chmod 755 {} \\;
    sudo find /home/user-sftp/wordpress -type f -exec chmod 644 {} \\;
    ```
    
3. **Open write access ONLY for the `wp-content` directory (Themes, Plugins, Uploads):**
    
    ```bash
    # Apply the SetGID magnet (2775) so new plugin folders inherit the www-data group
    sudo find /home/user-sftp/wordpress/wp-content -type d -exec chmod 2775 {} \;
    sudo find /home/user-sftp/wordpress/wp-content -type f -exec chmod 664 {} \;
    
    # Ensure the uploads directory exists before changing its ownership
    sudo mkdir -p /home/user-sftp/wordpress/wp-content/uploads
    
    # 2. Transfer absolute ownership of the uploads folder to the web server user AND group
    sudo chown -R www-data:www-data /home/user-sftp/wordpress/wp-content/uploads
    
    # 3. Apply standard Read/Write/Execute permissions for the owner/group
    sudo find /home/user-sftp/wordpress/wp-content/uploads -type d -exec chmod 775 {} \;
    sudo find /home/user-sftp/wordpress/wp-content/uploads -type f -exec chmod 664 {} \;
    ```
    
4. **Secure the configuration file:**
    
    ```bash
    sudo chmod 640 /home/user-sftp/wordpress/wp-config.php
    ```
    

## Phase 5: SSH Daemon Configuration

To ensure the connection is strictly limited to SFTP and immune to "Too many authentication failures" from background SSH keys, we configure a dedicated `Match User` block.

1. **Create the drop-in SSH configuration:**
Run the following command to securely write the rules to a new `.conf` file.
    
    ```bash
    sudo bash -c 'cat <<EOF > /etc/ssh/sshd_config.d/02-user-sftp.conf
    Match User user-sftp
        ForceCommand internal-sftp
        ChrootDirectory /home/user-sftp
        PasswordAuthentication yes
        PubkeyAuthentication no
        PermitTunnel no
        AllowAgentForwarding no
        AllowTcpForwarding no
        X11Forwarding no
    # CRITICAL: Reset the match scope so it does not leak into the global sshd_config
    Match All
    EOF'
    ```
    
2. **Restart the SSH service to apply the architecture:**
    
    ```bash
    sudo systemctl restart ssh sshd
    ```
    

## Phase 6: Client Connection Verification

1. Open FileZilla.
2. Open **Site Manager** (`Ctrl + S`).
3. Create a New Site with the following parameters:
    - **Protocol:** SFTP - SSH File Transfer Protocol
    - **Host:** Your VPS IP or Domain
    - **Port:** Your custom SSH port (e.g., `22343`)
    - **Logon Type:** Normal
    - **User:** `user-sftp`
    - **Password:** The password set in Phase 1.
4. Connect and verify that you can successfully upload a file into the `wordpress/wp-content/themes` directory, but are rejected if you try to modify files in the root `wordpress/` directory.
