# `acea.suse_aws.baseline`

Baseline di configurazione per SUSE Linux Enterprise. Ogni sezione ha il suo
interruttore `baseline_manage_*`, così il ruolo si può usare a pezzi.

Richiede `gather_facts: true` nel play. Supporta `--check --diff`.

| Sezione | Interruttore | Default | Cosa fa |
|---|---|:---:|---|
| Pacchetti | `baseline_manage_packages` | `true` | chrony, vim, curl, lsof, sysstat |
| Tempo | `baseline_manage_time` | `true` | Timezone + chrony sull'Amazon Time Sync (`169.254.169.123`) |
| Utenti | `baseline_manage_users` | `true` | Gruppo `opsadm`, sudoers, utenti e chiavi pubbliche |
| Kernel | `baseline_manage_sysctl` | `true` | `/etc/sysctl.d/99-ansible-baseline.conf` |
| motd | `baseline_manage_motd` | `true` | Banner "host gestito da AAP" |
| sshd | `baseline_manage_sshd` | **`false`** | Opt-in esplicito |

## Utenti operativi

```yaml
baseline_admin_users:
  - name: mrossi
    comment: "Mario Rossi"
    ssh_key: "ssh-ed25519 AAAA... mrossi@example.com"
```

L'elenco è vuoto di default: popolalo nelle group_vars o nelle Extra Variables
del Job Template.

## sshd

Disattivata di default. L'accesso avviene via Session Manager e non dipende da
`sshd`, ma resta una modifica che riguarda l'accesso agli host: attivala
consapevolmente con `baseline_manage_sshd=true`. Le direttive si configurano in
`baseline_sshd_settings` e ogni modifica passa da `sshd -t` come `validate`.

Documentazione completa: `ansible-doc -t role acea.suse_aws.baseline`

## Tag

`packages`, `time`, `users`, `sysctl`, `motd`, `sshd`:

```bash
ansible-playbook acea.suse_aws.baseline --tags time,motd
```
