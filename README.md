# OpenSigWeave

OpenSigWeave is a centralized, self-hosted email signature manager designed to bridge the gap between **Authentik** (Identity Management) and **Rspamd / Mailcow** (Mail Filtering). 

Instead of forcing users to configure signatures in their individual mail clients (Outlook, Apple Mail, mobile devices, etc.), OpenSigWeave injects rich HTML signatures at the gateway level. It dynamically pulls live user attributes (Phone, Title, Name) from Authentik and appends them to outgoing emails seamlessly.

## ✨ Key Features
* **Gateway-Level Injection:** Signatures are applied by the mail server, meaning they work identically across all devices and mail clients.
* **Authentik SSO Integration:** Login is gated strictly via Authentik OIDC. Live attributes (like phone numbers and job titles) are polled instantly during mail transit.
* **Rich Visual Editor:** A custom UI built with Tailwind CSS, Alpine.js, and Quill.js allows users and admins to design signatures visually or via raw HTML.
* **Domain-Level Master Templates:** Enforce a corporate signature standard across an entire domain.
* **User Overrides:** Allow specific users to customize their signatures, or administratively lock them out.
* **Intelligent Reply-Chain Detection:** An experimental Lua engine detects when an email is a reply and cleanly injects the signature *above* the quoted history (Supports Outlook, Apple Mail, Gmail, Thunderbird, etc.).
* **The "Kill Switch":** Easily disable signatures entirely for specific service accounts (e.g., `noreply@` or `billing@`).

---

## 🚀 1. Deploying the Web App

OpenSigWeave is a FastAPI application that utilizes an SQLite database. 

### Prerequisites
* Python 3.10+
* An active Authentik deployment
* An active Rspamd/Mailcow deployment

### Installation
1. Clone the repository to your application server.
   ```bash
   git clone [https://github.com/yourusername/opensigweave.git](https://github.com/yourusername/opensigweave.git)
   cd opensigweave
   ```
2. Install the required Python modules.
   ```bash
   pip install -r requirements.txt
   ```
3. Prepare your environment variables.
   ```bash
   cp .env.example .env
   nano .env
   ```
4. Prepare your branding (Optional).
   ```bash
   cp branding/logo.example.png branding/logo.png
   cp branding/settings.example.json branding/settings.json
   ```
5. Start the application (Recommendation: set this up as a `systemd` service for persistence).
   ```bash
   uvicorn main:app --host 0.0.0.0 --port 8000
   ```

### Authentik Setup
You will need two configurations in Authentik:
1. **OIDC Provider:** Create a standard OIDC Application/Provider for user logins. Ensure the scopes include `openid`, `email`, and `profile`.
2. **Service Account API Token:** Create an App Token (Intent: **API Token**) bound to an administrative account. This is required for the Rspamd engine to query user attributes securely in the background.

---

## 🛠️ 2. Deploying the Rspamd Lua Engine (Mailcow)

The web app is only half the puzzle. To actually inject signatures, you must deploy the provided Lua script into your Mailcow/Rspamd instance.

1. **Copy the Script:**
   Transfer the `opensigweave.lua` script from this repository into your Mailcow server's custom plugins directory:
   ```text
   /opt/mailcow-dockerized/data/conf/rspamd/plugins.d/opensigweave.lua
   ```

2. **Configure the Lua Script:**
   Open the Lua script and update the configuration block at the top with your OpenSigWeave API URL and the `ENGINE_API_KEY` you set in your `.env` file.

3. **Enable the Plugin:**
   Tell Rspamd to load the new plugin by adding an empty configuration block to your local overrides.
   Open `/opt/mailcow-dockerized/data/conf/rspamd/rspamd.conf.local` and add:
   ```hcl
   opensigweave { }
   ```

4. **Restart Rspamd:**
   Apply the changes by restarting the Mailcow Rspamd container.
   ```bash
   docker compose restart rspamd-mailcow
   ```

---

## 🔒 Security Notes
* OpenSigWeave's API endpoint (`/api/signature/{email}`) exposes employee metadata (Phone, Title, etc.) to successfully compile signatures. 
* This endpoint is strictly protected by the `X-Engine-Key` header. Ensure your `ENGINE_API_KEY` is a long, cryptographically secure string, and never expose it to frontend clients.
