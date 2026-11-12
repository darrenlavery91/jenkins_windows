# jenkins_windows

**Install**, **upgrade/downgrade** and **uninstall** Jenkins as a Windows service. Upgrades come with a Java compatibility matrix,
automatic Java install, full backup and automatic rollback, and a before/after plugin report.
Windows targets only. Collections: `ansible.windows`, `community.windows`
(`ansible-galaxy collection install -r requirements.yml`). `chocolatey.chocolatey` is optional and only
needed with `jenkins_java_install_method: chocolatey` (default is `msi`, which needs `jenkins_java_msi_urls`).

## What a run does

| Phase | Steps |
|---|---|
| **Plan** (always) | read current WAR + version from the startup definition (`.bat` or WinSW `jenkins.xml`; version from the WAR file name, else from the WAR manifest) -> look up which Java majors the target supports (`vars/main.yml`) -> discover installed JDKs -> pick one (or schedule an install) -> inventory plugins from `JENKINS_HOME\plugins` -> compare to update-center data for the target core -> estimate backup size vs free space |
| **Stage** (no downtime) | push WAR from the controller (`jenkins_war_controller_file`), copy from a share, or download from get.jenkins.io -> verify SHA-256 and the version/min-Java in the WAR manifest |
| **Java** | install the needed JDK side by side (MSI by default, or Chocolatey), without touching the machine PATH |
| **Drain/stop** | quiet-down + wait for builds (needs API token) -> stop service -> kill leftover `java.exe` |
| **Backup** | `JENKINS_HOME` (minus workspaces/caches), install dir, current WAR, original startup definition, service registry export, plugin list -> **verified** (robocopy `/L` compare against the live home must find nothing left to copy; `config.xml` and `plugins\` must exist) -> `manifest.json` (written last, records file count/size) |
| **Switch** | `.bat`: new WAR name + pinned `JAVA_HOME`/PATH block. WinSW `jenkins.xml`: new WAR name inside `<arguments>` + `<executable>` set to the selected `java.exe` (comments/formatting kept, result must parse as XML) |
| **Verify** | start -> health check -> `X-Jenkins` header equals target -> process really runs the new WAR -> ask Jenkins for failed/inactive plugins |
| **Plugins** | update plugins via Jenkins CLI (`install-plugin`), restart, re-verify |
| **Report** | Markdown report (controller `jenkins_reports/` + beside the backup): plugin updates (by core vs by plugin update), added, removed, **plugins that won't work** with reasons, warnings |
| **Rollback** | any failure after backup -> pre-check the backup (refuses before stopping anything if it is incomplete) -> restore startup definition, old WAR, `JENKINS_HOME` (mirror) -> start -> health check **and** `X-Jenkins` must equal the old version. Failure before the stop -> quiet-down is cancelled, Jenkins never went down |

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

## Modes (`jenkins_mode`)

| Mode | What it does | Example |
|---|---|---|
| `upgrade` (default) | everything below: plan, backup, switch, verify, plugin updates, rollback | `examples/upgrade.yml` |
| `install` | fresh install from a WAR, same layout as the official MSI (WinSW `jenkins.exe` + `jenkins.xml` + `jenkins-<version>.war`), so `upgrade` and rollback work on it unchanged | `examples/install.yml` |
| `uninstall` | removes the service (WinSW layout **or** the Jenkins MSI), stray `java.exe`, the install dir and the role's firewall rule; `JENKINS_HOME` only with `jenkins_uninstall_remove_home: true` (verified copy to `<jenkins_backup_dir>\<run_id>-uninstall` first) | `examples/uninstall.yml` |

`jenkins_plan_only: true` works in every mode and changes nothing.

### Install

1. Preflight (read-only): refuses if the service exists but is not WinSW in `jenkins_install_dir` (for example an MSI
   install elsewhere), if a **different** version is already installed (use `upgrade`), or if `jenkins_http_port` is taken.
2. Java: same matrix/selection/auto-install as an upgrade.
3. WAR from `jenkins_war_controller_file`, `jenkins_war_source_dir` or get.jenkins.io (SHA-256 + manifest checked).
   WinSW (`jenkins_winsw_url`, SHA-256 pinned) or `jenkins_winsw_controller_file` for air-gapped hosts.
4. `jenkins.xml` from a template (port, Java, `JENKINS_HOME`, webroot, `jenkins_install_java_opts`), service registered,
   start mode / account set, Windows Firewall rule `Jenkins (<service name>)` for the port.
5. A fresh `JENKINS_HOME` is restricted to SYSTEM + Administrators (+ the service account), because it holds `secrets\`.
6. **First login**: with `jenkins_admin_user` + `jenkins_admin_password` the setup wizard is skipped and a
   self-deleting `init.groovy.d` script creates that admin, turns off anonymous access and sets the Jenkins URL to
   `jenkins_url`. The role then proves it worked: anonymous gets 401/403, the admin logs in, and the script is gone. Then
   `jenkins_install_plugins` are installed through the CLI. Without credentials the wizard runs and the role prints
   the initial admin password.
7. Start, health check, `X-Jenkins` equals the target, the right WAR is running, install report.

Re-running converges. Plugins already present are skipped, and Jenkins is restarted only when something changed.
A reused `JENKINS_HOME` (one that already has `config.xml`) is left as is: no admin bootstrap, no ACL change.

## Usage

See `examples/upgrade.yml`, `examples/rollback.yml`, `examples/install.yml` and `examples/uninstall.yml`. Minimum variables:
`jenkins_target_version` (quoted!), `jenkins_home`, `jenkins_install_dir`, `jenkins_service_name`,
`jenkins_backup_dir`. Put `jenkins_admin_user` / `jenkins_admin_api_token` in Ansible Vault to enable
quiet-down, failed-plugin detection and plugin updates.

Manual rollback: `include_role` with `tasks_from: rollback` (newest *complete* backup, or `jenkins_rollback_backup_id`).
`jenkins_rollback_restore_home: false` restores only the WAR/startup definition and leaves `JENKINS_HOME` alone.

### Credentials

`jenkins_admin_api_token` should be an **API token** (User > Security > API Token). A password also works:
the role fetches a CSRF crumb in the same session for its POSTs (`files/Invoke-JenkinsApi.ps1`).
`jenkins_url` must match *Manage Jenkins > System > Jenkins URL*; otherwise the CLI (`-webSocket`) used for plugin
updates is rejected with `X-CLI-Error: Unexpected request origin`.

### Rollback drills

`jenkins_simulate_failure` makes a run fail on purpose so the rescue path can be proven on a real server:

| Value | What it proves |
|---|---|
| `before_stop` | failure before downtime: quiet-down cancelled, nothing restored, Jenkins never stopped |
| `after_backup` | Jenkins stopped + backup taken -> full automatic restore |
| `after_start` | new version running (and writing to `JENKINS_HOME`) -> full automatic restore to the old version |

```sh
ansible-playbook upgrade.yml -e jenkins_simulate_failure=after_start
```

## Startup definition: .bat or WinSW (jenkins.xml)

`jenkins_startup_script` can point at either kind; `jenkins_startup_type: auto` (default) treats a `.xml`
path as WinSW and anything else as a `.bat`. The official Jenkins MSI installs WinSW, typically:

```yaml
jenkins_service_name: Jenkins
jenkins_install_dir: 'C:\Program Files\Jenkins'
jenkins_startup_script: 'C:\Program Files\Jenkins\jenkins.xml'
# MSI default JENKINS_HOME is %LocalAppData%\Jenkins\.jenkins of the service account.
# For LocalSystem that is:
jenkins_home: 'C:\Windows\System32\config\systemprofile\AppData\Local\Jenkins\.jenkins'
```

The new WAR is staged as `jenkins-<version>.war` next to the old one; the XML is switched to it, so a
rollback is just restoring the XML (the old `jenkins.war` is left untouched).

## Things to know

* **JENKINS_HOME is not the install dir.** The WAR folder alone is not a backup. `jenkins_home` is required.
* **UNC WAR share over WinRM** hits the double-hop problem. Use CredSSP/Kerberos delegation, or
  `become: true` with `become_method: runas` and `become_flags: logon_type=new_credentials logon_flags=netcredentials_only`,
  or download from get.jenkins.io instead.
* Java is chosen by the **startup definition** (`.bat` managed block, or `<executable>` in `jenkins.xml`). If another
  wrapper (e.g. NSSM) sets its own `JAVA_HOME`/PATH, the role warns when the running `java.exe` differs from the selected JDK.
* **Win32-OpenSSH targets** (`ansible_connection=ssh`, `ansible_shell_type=powershell`): set the OpenSSH default shell to
  PowerShell, or modules fail with *"-EncodedCommand is not properly encoded"* (cmd.exe truncates the command at 8191 chars):
  `New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -PropertyType String -Force`
* An installed `jenkins.xml` keeps `-Djenkins.install.runSetupWizard=false` when the admin was bootstrapped. If
  `config.xml` is ever deleted, Jenkins would then start **without security**, so restore from a backup rather than
  starting on an empty home.
* Uninstall leaves Java installed and does not touch firewall rules the role did not create.
* Plugin updates use the Jenkins CLI, so *Jenkins itself* must reach the update center (or its proxy).
* "Won't work" detection is predictive before the upgrade (min core, min Java, missing hard dependencies,
  removed/deprecated/blocked-by-core in the update center) and authoritative after start-up (Jenkins' own failed-plugin list).
* Backups are plain robocopy trees (no zip) so a 50 GB home isn't compressed into one fragile archive.
* A restore is a robocopy **mirror** (`/PURGE`) of `JENKINS_HOME` (excluded dirs such as `workspace` are kept). That is
  why the backup is verified before `manifest.json` is written, and re-checked before a restore starts.
* A staged WAR that fails its SHA-256 / version check is deleted again (never the WAR in use).
