# aap-acea — demo Ansible Automation Platform su SUSE via AWS SSM

Progetto di esempio per provare **Ansible Automation Platform** contro una o
più **VM SUSE Linux Enterprise su AWS**, raggiunte via **AWS Systems Manager**
(Session Manager): niente porta 22 aperta, niente chiavi SSH da distribuire,
niente bastion host.

Tutta la logica di automazione sta in una collection versionata nel repo,
**`acea.suse_aws`**, organizzata in ruoli. I playbook in [playbooks/](playbooks/)
sono entry point sottili che servono a dare ai Job Template di AAP un path
stabile.

---

## Come funziona la connessione

```
┌──────────────────────┐      ssm:StartSession      ┌──────────────┐
│  AAP                 │ ─────────────────────────► │  AWS Systems │
│  Execution           │                            │  Manager     │
│  Environment         │ ◄───── canale WebSocket ──►│              │
│   • ansible-core     │                            └──────┬───────┘
│   • amazon.aws       │                                   │ il canale termina
│   • boto3            │      PutObject / GetObject         │ sull'SSM Agent
│   • session-manager- │ ──────────────┐                    ▼
│     plugin  ←← chiave│               │            ┌──────────────────┐
└──────────────────────┘               │            │  EC2 SLES 15     │
                                       ▼            │   amazon-ssm-    │
                              ┌─────────────────┐   │   agent (root)   │
                              │  Bucket S3 di   │◄──┤   sessione come  │
                              │  transito       │   │   ssm-user       │
                              └─────────────────┘   └──────────────────┘
```

Quattro cose non ovvie, ed è dove si inciampa:

1. **Il `session-manager-plugin` va nell'Execution Environment**, non sulla VM.
   Gli EE standard di Red Hat non lo contengono: serve un EE custom (è già
   pronto in [execution-environment/](execution-environment/)).
2. **Serve un bucket S3.** Il plugin non sa copiare file dentro la sessione
   Session Manager: genera un presigned URL, lo passa alla VM via SSM e la VM
   scarica il modulo con `curl`. Senza bucket, `raw` funziona ma `ping` no.
   Corollario: **la VM non ha bisogno di permessi IAM su S3** — l'autorizzazione
   sta nella firma dell'URL — ma deve avere `curl`.
3. **`ansible_user` / `remote_user` vengono ignorati.** La sessione parte come
   l'utente del documento Session Manager (di default `ssm-user`); per operare
   da root serve `become`.
4. **SSE-C non è supportato.** Il plugin sa dichiarare solo `AES256` (SSE-S3) e
   `aws:kms` (SSE-KMS): non emette mai gli header
   `x-amz-server-side-encryption-customer-*`. Se la policy del bucket di
   transito impone SSE-C, ogni modulo fallisce con 403 mentre i `raw` passano.
   Vedi [aws/README.md § SSE-C](aws/README.md#sse-c-non-è-utilizzabile).

> **Quale FQCN per il connection plugin?** Il plugin `aws_ssm` è stato promosso
> da `community.aws` ad `amazon.aws` con **amazon.aws 10.0.0**: in amazon.aws
> 9.x non esiste ancora. Il progetto usa `amazon.aws.aws_ssm` di default e si
> cambia da un solo punto — `ssm_connection_plugin` in
> [inventory/group_vars/all.yml](inventory/group_vars/all.yml). Il ruolo
> `ssm_preflight` verifica questo punto e lo segnala con un messaggio esplicito.

---

## Struttura

```
.
├── ansible.cfg                        config di base (inventario, callback, collections_path)
│
├── collections/
│   ├── requirements.yml               dipendenze esterne, risolte dal project sync di AAP
│   └── ansible_collections/acea/suse_aws/     ⭐ la collection di questo progetto
│       ├── galaxy.yml
│       ├── meta/runtime.yml
│       ├── roles/
│       │   ├── ssm_preflight/         diagnostica EE + AWS (gira sul nodo di esecuzione)
│       │   ├── ssm_connectivity/      smoke test della sessione SSM
│       │   ├── facts_report/          raccolta fact + rendering del report
│       │   ├── zypper_patching/       patching SLES in quattro fasi
│       │   ├── baseline/              pacchetti, tempo, utenti, sysctl, motd, sshd
│       │   └── webserver_nginx/       nginx + pagina demo, con percorso di rimozione
│       └── playbooks/                 preflight, connectivity, facts_report,
│                                      patching, webserver, baseline, site
│
├── playbooks/                         entry point sottili per i Job Template di AAP
│   ├── 00_ssm_ping.yml                → acea.suse_aws.connectivity
│   ├── 10_facts_report.yml            → acea.suse_aws.facts_report
│   ├── 20_zypper_patching.yml         → acea.suse_aws.patching
│   ├── 30_webserver_nginx.yml         → acea.suse_aws.webserver
│   ├── 40_baseline_hardening.yml      → acea.suse_aws.baseline
│   ├── 99_preflight_check.yml         → acea.suse_aws.preflight
│   └── site.yml                       → acea.suse_aws.site
│
├── inventory/
│   ├── aws_ec2.yml                    inventario dinamico EC2 (filtra tag AnsibleManaged=true)
│   ├── static_demo.yml                inventario statico per il primo test
│   └── group_vars/
│       ├── all.yml                    region, bucket, scelta del connection plugin
│       └── suse_servers.yml           ⭐ tutte le variabili di connessione SSM
│
├── execution-environment/             EE custom con session-manager-plugin
│   ├── execution-environment.yml
│   ├── requirements.{yml,txt}
│   ├── bindep.txt
│   ├── build.sh
│   └── README.md                      i tranelli di ansible-builder su ee-minimal
│
├── aap/
│   ├── controller_setup.yml           config-as-code: progetto, credential, JT, workflow
│   ├── requirements.yml
│   └── vars/main.yml                  ⭐ parametri da personalizzare
│
└── aws/
    ├── setup-ssm-demo.sh              crea bucket, ruoli IAM e (opz.) una SLES di prova
    ├── userdata-sles-ssm.sh           cloud-init: installa e avvia amazon-ssm-agent
    ├── iam-policy-ec2-instance.json
    ├── iam-policy-aap-controller.json
    └── README.md                      spiegazione dettagliata dei permessi
```

### Perché una collection e non solo dei ruoli

- **Versionabile e distribuibile**: `ansible-galaxy collection build` produce un
  artefatto pubblicabile su Automation Hub, con le sue dipendenze dichiarate in
  `galaxy.yml`. Altri team la consumano senza copiare file.
- **Namespace stabile**: `acea.suse_aws.zypper_patching` non collide con nulla.
- **Documentata dagli strumenti**: i ruoli con `meta/argument_specs.yml` validano
  i parametri all'avvio del play e si leggono con
  `ansible-doc -t role acea.suse_aws.zypper_patching`.

Dettagli sulla collection: [README della collection](collections/ansible_collections/acea/suse_aws/README.md).

### Divisione delle responsabilità

| Dove | Cosa ci sta |
|---|---|
| **Inventario** (`inventory/group_vars/`) | Come ci si connette: `ansible_connection`, `ansible_aws_ssm_*`, `become`. Non è roba da ruolo. |
| **Ruolo** | Cosa fare sull'host, con variabili prefissate col nome del ruolo e default prudenti. |
| **Playbook della collection** | Scelte di play: `hosts`, `gather_facts`, `serial`, `max_fail_percentage`. |
| **Entry point** (`playbooks/`) | Solo un `import_playbook`: dà ai Job Template un path stabile. |
| **AAP** | Chi può lanciare cosa, su quale inventario, con quali survey e credential. |

---

## Setup in quattro passi

### 1. Lato AWS

```bash
cd aws
REGION=eu-south-1 ./setup-ssm-demo.sh --with-instance
```

Crea il bucket di transito, il ruolo IAM + instance profile per le EC2, la
policy IAM per AAP e — con `--with-instance` — una SLES 15 senza IP pubblico
esposto e senza chiave SSH, già taggata `AnsibleManaged=true`. Lo script
attende che l'istanza risulti `Online` in SSM (2-5 minuti).

Poi aggancia la policy `aap-acea-aap-controller-policy` all'utente o al ruolo
IAM che userai nella credential AWS di AAP.

Hai già le VM? Ti serve solo che ciascuna abbia:

- `amazon-ssm-agent` installato e attivo (vedi
  [userdata-sles-ssm.sh](aws/userdata-sles-ssm.sh));
- un instance profile con `AmazonSSMManagedInstanceCore` — e basta: i
  trasferimenti passano da presigned URL, la VM non autentica nulla verso S3;
- `curl` presente (su SLES 15 c'è di serie);
- uscita sulla 443 verso `ssm`, `ssmmessages`, `ec2messages` (NAT gateway o VPC
  endpoint) e verso S3;
- il tag `AnsibleManaged=true` (usato dall'inventario dinamico e dalla
  `Condition` IAM su `ssm:StartSession`).

I dettagli sono in [aws/README.md](aws/README.md).

### 2. L'Execution Environment

```bash
pip install ansible-builder
podman login registry.redhat.io

cd execution-environment
REGISTRY=quay.io/tua-org PUSH=true IMAGE_TAG=1.0.0 ./build.sh
```

Lo script verifica nell'immagine appena costruita che
`session-manager-plugin --version` risponda, che `boto3` sia importabile e che
le collection ci siano. Se non hai una subscription Red Hat, cambia
`base_image` in `quay.io/ansible/awx-ee:latest`.

### 3. Configurazione di AAP

Via API (consigliato):

```bash
ansible-galaxy collection install -r aap/requirements.yml

# In AAP 2.5+ il controller sta dietro al gateway: usa l'URL del gateway.
export CONTROLLER_HOST=https://aap.example.com
export CONTROLLER_USERNAME=admin
export CONTROLLER_PASSWORD='...'
export CONTROLLER_VERIFY_SSL=false        # solo in lab

# prima personalizza aap/vars/main.yml (URL del repo, immagine EE, region, bucket)
ansible-playbook aap/controller_setup.yml \
  -e aws_access_key=AKIA... -e aws_secret_key=...
```

Crea credential AWS, EE, progetto git, inventario dinamico, sei job template
con survey e un workflow di onboarding. Le variabili delle survey sono
esattamente quelle dei ruoli: nessun mapping intermedio da mantenere.

<details>
<summary>Oppure a mano dalla UI</summary>

1. **Credential** → tipo *Amazon Web Services*, access key + secret key.
2. **Execution Environment** → immagine costruita al passo 2, pull *Always*.
3. **Project** → git, questo repo, EE di default = quello nuovo.
4. **Inventory** → variabili `aws_region` e `ssm_transfer_bucket`.
5. **Inventory Source** → *Sourced from a Project*, file
   `inventory/aws_ec2.yml`, credential AWS, *Update on launch*.
6. **Job Template** → progetto + inventario + playbook + credential AWS + EE.
</details>

### 4. Primo test

Nell'ordine:

```
SUSE / 99 - Preflight check EE e AWS     ← verifica EE, credential, bucket, SSM
SUSE / 00 - Verifica connettivita SSM    ← apre la sessione e fa ping
SUSE / 10 - Report inventario            ← raccoglie i fact
SUSE / 30 - Deploy webserver nginx       ← modifica qualcosa davvero
```

---

## I ruoli

| Ruolo | Dove gira | Cosa fa | Modifica gli host |
|---|---|---|:---:|
| [`ssm_preflight`](collections/ansible_collections/acea/suse_aws/roles/ssm_preflight/) | nodo di esecuzione | `session-manager-plugin`, boto3, connection plugin, credenziali AWS, bucket S3, registrazione SSM dell'istanza | no |
| [`ssm_connectivity`](collections/ansible_collections/acea/suse_aws/roles/ssm_connectivity/) | target | Utente di sessione, `become`, trasferimento modulo via S3 | no |
| [`facts_report`](collections/ansible_collections/acea/suse_aws/roles/facts_report/) | target + locale | Fact, pacchetti, servizi, repo zypper, stato SCC; report markdown | no |
| [`zypper_patching`](collections/ansible_collections/acea/suse_aws/roles/zypper_patching/) | target | Precondizioni, censimento, patching per categoria, riavvio condizionato | sì |
| [`baseline`](collections/ansible_collections/acea/suse_aws/roles/baseline/) | target | Pacchetti, timezone e NTP, utenti operativi, sysctl, motd, sshd (opt-in) | sì |
| [`webserver_nginx`](collections/ansible_collections/acea/suse_aws/roles/webserver_nginx/) | target | nginx + pagina demo; `absent` rimuove tutto | sì |

Ogni ruolo ha il suo README con la tabella completa delle variabili.

---

## Provarlo in locale, senza AAP

Utile per iterare in fretta prima di impacchettare l'EE. La collection del repo
viene risolta grazie a `collections_path = collections` in `ansible.cfg`:

```bash
# dipendenze locali
pip install boto3 botocore jmespath
ansible-galaxy collection install -r collections/requirements.yml

# il session-manager-plugin serve anche qui
curl -o /tmp/smp.rpm https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
sudo rpm -Uvh /tmp/smp.rpm        # su Debian/Ubuntu usa il .deb

export AWS_PROFILE=tuo-profilo
export AWS_REGION=eu-south-1

# la collection è visibile?
ansible-galaxy collection list | grep acea

# prima il preflight
ansible-playbook acea.suse_aws.preflight \
  -e aws_region=eu-south-1 \
  -e ssm_transfer_bucket=IL-TUO-BUCKET \
  -e ssm_preflight_instance_id=i-0123456789abcdef0

# poi lo smoke test (inventario dinamico)
ansible-playbook acea.suse_aws.connectivity

# oppure con l'inventario statico, dopo averci messo i tuoi instance-id
ansible-playbook -i inventory/static_demo.yml playbooks/00_ssm_ping.yml
```

Prima di committare:

```bash
ansible-playbook --syntax-check playbooks/*.yml
ansible-lint
ansible-inventory -i inventory/aws_ec2.yml --graph
ansible-doc -t role acea.suse_aws.zypper_patching
```

---

## Troubleshooting

| Sintomo | Causa quasi sempre |
|---|---|
| `Unable to find session-manager-plugin` | Il plugin non è nell'EE. Il job usa l'EE giusto? È un EE custom o quello di default? |
| `couldn't resolve module/action 'amazon.aws.aws_ssm'` | amazon.aws < 10.0.0 nell'EE: imposta `ssm_connection_plugin=community.aws.aws_ssm` oppure aggiorna la collection |
| `the role 'acea.suse_aws.x' was not found` | La collection del progetto non è nel collections path di AAP: decommenta il blocco git in [collections/requirements.yml](collections/requirements.yml) |
| I task `raw` passano, `ping` fallisce con errore S3 | Bucket mancante o nome sbagliato, permessi `s3:PutObject`/`GetObject` assenti sull'identità di AAP, oppure **la policy del bucket impone SSE-C** |
| `AccessDenied` sul PUT pur avendo `s3:PutObject` | Policy del bucket che pretende `x-amz-server-side-encryption-customer-algorithm`: il plugin non sa emetterlo. Serve un bucket di transito con SSE-S3 o SSE-KMS |
| `curl: command not found` nell'output di un task | La VM non ha `curl`: il plugin lo usa per scaricare i moduli dal presigned URL |
| `An error occurred (AccessDeniedException) ... ssm:StartSession` | Alla credential AAP manca `ssm:StartSession`, oppure l'istanza non ha il tag `AnsibleManaged=true` richiesto dalla `Condition` |
| `TargetNotConnected` | L'SSM Agent non è registrato: `systemctl status amazon-ssm-agent` sulla VM, instance profile presente, uscita sulla 443 verso `ssmmessages` |
| Inventario vuoto dopo il sync | Tag `AnsibleManaged=true` mancante, region sbagliata, o istanze non in stato `running` |
| `Permission denied` sui task | Manca `become`: la sessione è `ssm-user`, non root. Le variabili stanno in `inventory/group_vars/suse_servers.yml` |
| `/usr/bin/python3: not found` | Immagine SLES minimale: installa `python3-base` (lo fa già lo user-data) |
| Connessione lenta, ~2-3 s per task | È fisiologico: ogni task passa da S3. Alza `forks`, riduci il numero di task, usa `gather_facts: false` dove puoi |
| `could not resolve the module_defaults group ansible.controller.controller` | `ansible.controller` non installata: `ansible-galaxy collection install -r aap/requirements.yml` |
| Build dell'EE: `assemble: /usr/bin/dnf: No such file or directory` | Le immagini `ee-minimal` hanno `microdnf`, non `dnf`: serve `options.package_manager_path: /usr/bin/microdnf`. Vedi [execution-environment/README.md](execution-environment/README.md) |

Comandi utili:

```bash
# le istanze sono registrate?
aws ssm describe-instance-information --region eu-south-1 --output table \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Name:ComputerName}'

# shell manuale sulla VM
aws ssm start-session --region eu-south-1 --target i-0123456789abcdef0

# log dell'agent, dalla VM
sudo journalctl -u amazon-ssm-agent -n 100
sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log
```

Per vedere cosa fa il plugin, lancia il job con verbosity 4 (`-vvvv`): stampa i
comandi inviati nella sessione e le chiamate S3.

---

## Note di sicurezza

- **Il bucket di transito non deve avere il versioning attivo.** Il plugin
  cancella gli oggetti temporanei, ma le versioni precedenti restano e
  contengono il payload dei moduli (variabili comprese). Lo script di setup
  aggiunge anche una lifecycle rule a 1 giorno.
- `ssm:StartSession` è ristretto per tag: AAP può aprire sessioni solo verso le
  istanze che gestisce davvero.
- Session Manager registra chi ha aperto cosa in CloudTrail; puoi abilitare
  anche il logging del contenuto delle sessioni su S3 o CloudWatch Logs dalle
  preferenze di Session Manager.
- Le chiavi AWS stanno nella credential di AAP, non nel repo. `aap/vars/main.yml`
  ha i campi vuoti apposta: passale come extra vars o da vault.
- Il security group della demo non ha **nessuna** regola in ingresso.

---

## Riferimenti

- [`amazon.aws.aws_ssm` connection plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ssm_connection.html)
  — promosso da `community.aws` ad `amazon.aws` con amazon.aws 10.0.0
- [`amazon.aws.aws_ec2` inventory plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html)
- [Creating and using execution environments (AAP 2.6)](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html-single/creating_and_using_execution_environments/index)
- [Installare l'SSM Agent su SUSE Linux Enterprise Server](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-suse.html)
- [`community.general.zypper`](https://docs.ansible.com/ansible/latest/collections/community/general/zypper_module.html)
- [Role argument validation](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#role-argument-validation)
