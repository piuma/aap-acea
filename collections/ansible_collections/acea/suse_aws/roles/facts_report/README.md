# `acea.suse_aws.facts_report`

Raccoglie fact, pacchetti installati, servizi systemd, repository zypper e
stato della registrazione SCC/RMT, e li aggrega in un report markdown.

Il ruolo ha **due punti di ingresso**:

- `tasks/main.yml` — gira sugli host target e raccoglie;
- `tasks/render.yml` — gira in locale e rende il report leggendo gli hostvars
  degli host raccolti nel play precedente.

```yaml
- hosts: suse_servers
  gather_facts: true
  roles:
    - role: acea.suse_aws.facts_report

- hosts: localhost
  connection: local
  gather_facts: true
  tasks:
    - ansible.builtin.include_role:
        name: acea.suse_aws.facts_report
        tasks_from: render
```

## Variabili

| Variabile | Default | Note |
|---|---|---|
| `facts_report_path` | `/tmp/suse_inventory_report.md` | Dentro l'EE il filesystem è effimero |
| `facts_report_print` | `true` | Stampa il report nel log del job |
| `facts_report_group` | `suse_servers` | Gruppo su cui itera il rendering |
| `facts_report_watched_services` | sshd, amazon-ssm-agent, nginx, chronyd, firewalld | Colonne della tabella servizi |
| `facts_report_collect_packages` | `true` | Ogni raccolta ha un costo: passa dal bucket S3 |
| `facts_report_collect_services` | `true` | |
| `facts_report_collect_zypper` | `true` | |

Per archiviare il report invece di stamparlo, aggiungi nel playbook chiamante
un task `amazon.aws.s3_object` che carichi `facts_report_path` su un bucket.
