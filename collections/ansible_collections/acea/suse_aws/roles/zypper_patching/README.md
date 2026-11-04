# `acea.suse_aws.zypper_patching`

Patching di SUSE Linux Enterprise con `zypper`, in quattro fasi separate
(`tasks/assert.yml`, `report.yml`, `apply.yml`, `reboot.yml`).

Il default è **prudente**: senza una scelta esplicita il ruolo si limita a
elencare cosa verrebbe installato (`zypper_patching_check_only: true`).

Richiede `gather_facts: true` nel play: le precondizioni leggono `os_family` e
`mounts`.

> La strategia di rollout — `serial`, `max_fail_percentage` — è una keyword di
> **play**: va espressa nel playbook chiamante, non qui.

## Variabili

| Variabile | Default | Note |
|---|---|---|
| `zypper_patching_type` | `security` | `security` \| `recommended` \| `all` |
| `zypper_patching_check_only` | `true` | Solo censimento, nessuna modifica |
| `zypper_patching_allow_reboot` | `false` | Il riavvio viene comunque *rilevato* e segnalato |
| `zypper_patching_reboot_timeout` | `900` | Generoso: dopo il boot anche l'SSM Agent deve ri-registrarsi |
| `zypper_patching_post_reboot_delay` | `30` | |
| `zypper_patching_refresh_cache` | `true` | `zypper refresh` prima del censimento |
| `zypper_patching_min_free_bytes` | `1073741824` | 1 GiB minimo su `/` o `/var` |
| `zypper_patching_log_path` | `/var/log/ansible-patching.log` | |
| `zypper_patching_write_log` | `true` | |

Documentazione completa: `ansible-doc -t role acea.suse_aws.zypper_patching`

## Tag

`assert`, `report`, `apply`, `reboot` — utili per rieseguire solo una fase:

```bash
ansible-playbook acea.suse_aws.patching --tags report
```

## Esempio

```yaml
- hosts: suse_servers
  gather_facts: true
  serial: 2
  max_fail_percentage: 20
  roles:
    - role: acea.suse_aws.zypper_patching
      vars:
        zypper_patching_type: security
        zypper_patching_check_only: false
        zypper_patching_allow_reboot: true
```

## Note

- `zypper needs-rebooting` esce con `0` se il riavvio non serve e con `102` se
  serve: il ruolo tratta entrambi come successo.
- Il riavvio funziona anche su connessione `aws_ssm`, perché il plugin riapre
  la sessione Systems Manager — serve però il timeout generoso di default.
