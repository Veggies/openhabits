# OpenHabits: Self-Hosted Security Hardening

This guide provides practical security recommendations for people running their own OpenHabits server. It supplements the [server setup guide](SERVER.md) and [server configuration reference](../apps/server/README.md).

These recommendations are deployment precautions, not a claim that a particular vulnerability exists in OpenHabits.

## 1. Limit network exposure

OpenHabits uses port 8080 for its local setup page and port 8443 for its built-in remote HTTPS connection.

- Keep the local HTTP setup interface (8080) restricted to trusted networks. Do not forward port 8080 from your router to the public internet.
- If you enable remote access, expose only the port required for your chosen configuration.
- OpenHabits can use UPnP to request router port forwarding. Review your router's forwarding rules and remove any rules you no longer need.
- If you do not need access from outside your home, leave remote access disabled.
- For remote access, use OpenHabits' built-in HTTPS or a securely configured reverse proxy or server-side tunnel. Avoid configurations that require installing additional software on each device.

**Note:** The default Docker Compose deployment uses host networking. Review the host's firewall rules because Docker network isolation differs when host networking is enabled.

## 2. Protect remote connections

OpenHabits supports its own certificate for remote access and can also work behind a reverse proxy or tunnel using `PUBLIC_URL`.

- Use HTTPS for connections over untrusted networks.
- When using a reverse proxy, configure TLS correctly and keep the proxy updated.
- Do not bypass certificate validation to work around connection errors.
- Only set `TRUST_PROXY` when using a trusted, correctly configured proxy. Review which clients can reach the server and supply forwarding headers.
- Treat the server address and QR-code device pairing information as connection details to share only with intended users.

For supported remote access options, see [Setting up the OpenHabits server](SERVER.md).

## 3. Secure accounts and credentials

- Use a strong, unique password for the server owner account.
- Give each household member their own account instead of sharing credentials.
- Protect computers and mobile devices that are signed in to the server with device-level authentication.
- If using `OWNER_USERNAME` and `OWNER_PASSWORD` during automated setup, avoid committing real credentials to Git repositories or including them in shared configuration files.
- Restrict access to deployment environment files, backups, and any system containing account credentials.

## 4. Harden the Docker host

The published server image is `ghcr.io/veggies/openhabits-server`.

- Keep the host operating system and Docker engine updated.
- Review release notes before updating the OpenHabits image.
- For controlled deployments, pin a specific published image version rather than automatically following `latest`.
- Restrict administrative access to the Docker host and its management interface.
- Protect the server's data folder (`/data` by default) using appropriate filesystem permissions.
- Avoid granting additional container privileges, host mounts, or access to the Docker socket unless explicitly required and understood.

These precautions apply to the deployment environment; they do not imply that the default container configuration is vulnerable.

## 5. Back up and protect stored data

OpenHabits keeps its server data in the folder that holds the database file set by `DB_PATH`. That's `/data` unless you changed `DB_PATH`. The folder holds the SQLite database, the server's certificate, and the signing key that signed-in devices use to recognise the server. If you restore without the signing key, your devices won't recognise it as the same server.

- Back up that whole folder regularly.
- Store backups somewhere protected from unauthorized access.
- Encrypt backups when they contain sensitive personal information.
- Test restoration periodically so backups are known to work.
- Stop the container before copying database files, or use SQLite's supported online backup method as described in the server documentation.
- Protect backup copies of the certificate and signing key as carefully as the live server.

## 6. Review your deployment periodically

After installation and following major changes:

- Confirm only intended ports are accessible from outside your network.
- Check for unexpected router forwarding rules.
- Verify that remote access still uses valid HTTPS connections.
- Review who has access to the server and its host.
- Check for OpenHabits and operating system security updates.
- Verify that recent backups can be restored.

## Reporting security vulnerabilities

If you discover a suspected vulnerability in OpenHabits itself, do not publish exploitation details in a public issue.

Follow the project's [security reporting policy](../SECURITY.md) and use GitHub's private vulnerability reporting process.

This guide is intended to help administrators reduce deployment risk. It is not a security audit or a guarantee that a deployment is secure.
