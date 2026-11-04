# `acea.suse_aws.ssm_preflight`

Diagnostica i prerequisiti dell'automazione SSM. **Gira sul nodo di esecuzione**
(dentro l'Execution Environment), non apre sessioni verso gli host target: è il
primo playbook da lanciare quando qualcosa non funziona.

Controlla, in quest'ordine:

1. `session-manager-plugin` presente e funzionante nell'EE;
2. versioni di `boto3` / `botocore`;
3. collection richieste installate;
4. il connection plugin SSM è risolvibile con l'FQCN configurato;
5. identità AWS effettiva (`sts:GetCallerIdentity`);
6. bucket S3 di transito: esistenza, versioning, default encryption, e
   soprattutto **se la bucket policy impone SSE-C** — che il connection plugin
   non sa soddisfare; più, opzionalmente, un put/delete reale per provare i
   permessi IAM;
7. se passi un instance ID: esistenza, instance profile, tag `AnsibleManaged`,
   registrazione nell'inventario Systems Manager.

## Variabili principali

| Variabile | Default | Note |
|---|---|---|
| `ssm_preflight_region` | da `aws_region` | Regione AWS |
| `ssm_preflight_bucket` | da `ssm_transfer_bucket` | Obbligatoria: il ruolo fallisce con un messaggio esplicito se manca |
| `ssm_preflight_plugin_path` | `/usr/local/bin/session-manager-plugin` | Path atteso nell'EE |
| `ssm_preflight_connection_plugin` | da `ssm_connection_plugin` | FQCN da verificare |
| `ssm_preflight_instance_id` | `""` | Vuoto salta i controlli sull'istanza |
| `ssm_preflight_test_bucket_rw` | `true` | Put/delete reale sul bucket |

Documentazione completa: `ansible-doc -t role acea.suse_aws.ssm_preflight`

## Esempio

```yaml
- hosts: localhost
  connection: local
  gather_facts: true
  roles:
    - role: acea.suse_aws.ssm_preflight
      vars:
        ssm_preflight_instance_id: i-0123456789abcdef0
```
