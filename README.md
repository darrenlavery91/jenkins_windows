# jenkins_windows

Upgrade (or downgrade) the Jenkins **WAR + Windows service** with a Java compatibility matrix,
automatic Java install, full backup and automatic rollback, and a before/after plugin report.
Windows targets only. Collections: `ansible.windows`, `community.windows`
(`ansible-galaxy collection install -r requirements.yml`). `chocolatey.chocolatey` is optional and only
needed with `jenkins_java_install_method: chocolatey` (default is `msi`, which needs `jenkins_java_msi_urls`).

## What a run does

| Phase | Steps |
|---|---|
| **Plan** (always) | read current version from the startup script -> look up which Java majors the target supports (`vars/main.yml`) -> discover installed JDKs -> pick one (or schedule an install) -> inventory plugins from `JENKINS_HOME\plugins` -> compare to update-center data for the target core -> estimate backup size vs free space |
| **Stage** (no downtime) | copy WAR from share (or download from get.jenkins.io) -> verify SHA-256 and the version/min-Java in the WAR manifest |
| **Java** | install the needed JDK side by side (MSI by default, or Chocolatey), without touching the machine PATH |
| **Drain/stop** | quiet-down + wait for builds (needs API token) -> stop service -> kill leftover `java.exe` |
| **Backup** | `JENKINS_HOME` (minus workspaces/caches), install dir, current WAR, original startup script, service registry export, plugin list, `manifest.json` (written last) |
| **Switch** | patch the startup script: new WAR name + pinned `JAVA_HOME`/PATH block |
| **Verify** | start -> health check -> `X-Jenkins` header equals target -> process really runs the new WAR -> ask Jenkins for failed/inactive plugins |
| **Plugins** | update plugins via Jenkins CLI (`install-plugin`), restart, re-verify |
| **Report** | Markdown report (controller `jenkins_reports/` + beside the backup): plugin updates (by core vs by plugin update), added, removed, **plugins that won't work** with reasons, warnings |
| **Rollback** | any failure after backup -> restore startup script, old WAR, `JENKINS_HOME` -> start -> health check |

`jenkins_plan_only: true` stops after Plan and writes the report; nothing on the server changes.

## Java rules (from jenkins.io/doc/book/platform-information/support-policy-java)

| Java | Supported core (weekly) | First LTS |
|---|---|---|
| 17 | 2.340 - **2.544** (final) | 2.346.1 - final 2.541.3 |
| 21 | 2.463+ | 2.479.1 |
| 25 | 2.534+ | 2.541.1 |

So `2.544` runs on Java 17, 21 and 25. Anything newer than 2.544 needs Java 21+.
With `jenkins_java_strategy: minimal` (default) an already installed supported JDK is reused;
`preferred` moves to `jenkins_java_preference[0]` (21) even if 17 is present.
When the policy changes, edit `jenkins_java_support` in `vars/main.yml`.

## Usage

See `examples/upgrade.yml` and `examples/rollback.yml`. Minimum variables:
`jenkins_target_version` (quoted!), `jenkins_home`, `jenkins_install_dir`, `jenkins_service_name`,
`jenkins_backup_dir`. Put `jenkins_admin_user` / `jenkins_admin_api_token` in Ansible Vault to enable
quiet-down, failed-plugin detection and plugin updates.

Manual rollback: `include_role` with `tasks_from: rollback` (newest backup, or `jenkins_rollback_backup_id`).

## Things to know

* **JENKINS_HOME is not the install dir.** The WAR folder alone is not a backup. `jenkins_home` is required.
* **UNC WAR share over WinRM** hits the double-hop problem. Use CredSSP/Kerberos delegation, or
  `become: true` with `become_method: runas` and `become_flags: logon_type=new_credentials logon_flags=netcredentials_only`,
  or download from get.jenkins.io instead.
* Java is chosen by the **startup script**. If your service wrapper (NSSM/WinSW) sets its own `JAVA_HOME`/PATH,
  the role warns when the running `java.exe` differs from the selected JDK.
* Plugin updates use the Jenkins CLI, so *Jenkins itself* must reach the update center (or its proxy).
* "Won't work" detection is predictive before the upgrade (min core, min Java, missing hard dependencies,
  removed/deprecated/blocked-by-core in the update center) and authoritative after start-up (Jenkins' own failed-plugin list).
* Backups are plain robocopy trees (no zip) so a 50 GB home isn't compressed into one fragile archive.
