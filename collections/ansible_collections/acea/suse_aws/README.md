# Collection `acea.suse_aws`

Automazione di istanze **SUSE Linux Enterprise su AWS** raggiunte via **Systems
Manager** (Session Manager): niente SSH, niente bastion, niente chiavi da
distribuire.

Tutta la logica sta nei ruoli. I playbook sono sottili e servono solo a
comporre i ruoli e a dichiarare le scelte che sono di *play* e non di ruolo —
`hosts`, `gather_facts`, `serial`, `max_fail_percentage`.

## Ruoli

| Ruolo | Dove gira | Cosa fa |
|---|---|---|
| [`ssm_preflight`](roles/ssm_preflight/) | nodo di esecuzione | Verifica `session-manager-plugin`, boto3, connection plugin, credenziali AWS, bucket S3 (SSE-C compresa), registrazione SSM dell'istanza |
| [`ssm_connectivity`](roles/ssm_connectivity/) | target | Smoke test: utente di sessione, `become`, trasferimento modulo via S3 |
| [`facts_report`](roles/facts_report/) | target + locale | Raccoglie fact, pacchetti, servizi e stato SCC; rende un report markdown |
| [`zypper_patching`](roles/zypper_patching/) | target | Precondizioni, censimento, patching per categoria, riavvio condizionato |
| [`baseline`](roles/baseline/) | target | Pacchetti, timezone e NTP, utenti operativi, sysctl, motd, sshd (opt-in) |
| [`webserver_nginx`](roles/webserver_nginx/) | target | nginx + pagina demo; supporta anche la rimozione |

I ruoli che toccano gli host richiedono `gather_facts: true` nel play.

## Playbook

| Playbook | FQCN |
|---|---|
| Preflight EE e AWS | `acea.suse_aws.preflight` |
| Verifica connettività | `acea.suse_aws.connectivity` |
| Report inventario | `acea.suse_aws.facts_report` |
| Patching | `acea.suse_aws.patching` |
| Webserver | `acea.suse_aws.webserver` |
| Baseline | `acea.suse_aws.baseline` |
| Convergenza completa | `acea.suse_aws.site` |

```bash
ansible-playbook acea.suse_aws.connectivity
ansible-playbook acea.suse_aws.patching -e zypper_patching_check_only=false
```

## Uso dei ruoli in un playbook proprio

```yaml
- name: Patching della finestra notturna
  hosts: suse_servers
  gather_facts: true
  serial: 2
  roles:
    - role: acea.suse_aws.zypper_patching
      vars:
        zypper_patching_type: security
        zypper_patching_check_only: false
        zypper_patching_allow_reboot: true
```

## Convenzioni

- Ogni ruolo prefissa le proprie variabili con il nome del ruolo.
- I ruoli con una superficie di configurazione ampia hanno
  `meta/argument_specs.yml`: Ansible valida i parametri all'avvio e
  `ansible-doc -t role acea.suse_aws.<ruolo>` ne stampa la documentazione.
- I ruoli non decidono *dove* girano né *quanti host alla volta*: quelle sono
  scelte del playbook chiamante.
- Le variabili di connessione (`ansible_connection`, `ansible_aws_ssm_*`) non
  stanno nei ruoli: appartengono all'inventario.

## Build e pubblicazione

```bash
cd collections/ansible_collections/acea/suse_aws
ansible-galaxy collection build --force
ansible-galaxy collection publish acea-suse_aws-1.0.0.tar.gz \
  --server https://console.redhat.com/api/automation-hub/ --api-key "$AH_TOKEN"
```

Pubblicata su Automation Hub, si aggiunge a `collections/requirements.yml` del
progetto AAP e viene installata dal project sync come qualsiasi altra
collection.

## Dipendenze

`amazon.aws`, `community.aws`, `community.general`, `ansible.posix` — vedi
[galaxy.yml](galaxy.yml).

Il **connection plugin** `aws_ssm` è passato da `community.aws` ad `amazon.aws`
con **amazon.aws 10.0.0**: su un EE con amazon.aws 9.x va usato ancora
`community.aws.aws_ssm`. Il ruolo `ssm_preflight` verifica questo punto e lo
segnala con un messaggio esplicito.

Lo stesso ruolo verifica anche che il bucket di transito non imponga **SSE-C**,
modalità che il plugin non sa usare: trasferisce i file con presigned URL +
`curl` ed emette al massimo gli header `x-amz-server-side-encryption`.
