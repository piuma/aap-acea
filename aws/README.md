# Lato AWS

Tre pezzi, e se ne manca uno la connessione SSM non parte.

## Come viaggiano davvero i file

Vale la pena sapere esattamente cosa fa il plugin, perché determina i permessi
che servono e perché SSE-C non funziona:

1. il **controller** genera un **presigned URL** per il bucket (PUT o GET,
   validità un'ora);
2. passa quell'URL alla VM attraverso la sessione Session Manager;
3. la **VM esegue `curl`** su quell'URL per scaricare il modulo (o caricare il
   risultato di un `fetch`).

Due conseguenze dirette:

- **la VM non ha bisogno di credenziali IAM per S3.** L'autorizzazione viaggia
  nella firma del presigned URL. All'instance profile basta
  `AmazonSSMManagedInstanceCore`.
- **la VM deve avere `curl`.** Su SLES 15 c'è di serie.

## 1. Il bucket S3 di transito

Il connection plugin `aws_ssm` **non** copia i moduli Ansible dentro la sessione
Session Manager: li fa transitare da un bucket S3. Senza bucket il plugin non
funziona proprio — si vede bene perché i task `raw` passano e `ping` no.

Caratteristiche consigliate:

- **versioning disabilitato** — il plugin cancella gli oggetti temporanei, ma
  con il versioning attivo le versioni precedenti restano e contengono il
  payload dei moduli trasferiti;
- cifratura di default SSE-S3 (`AES256`) oppure SSE-KMS (in quel caso aggiungi
  `kms:Decrypt` e `kms:GenerateDataKey` all'identità del controller);
- block public access completo;
- lifecycle rule di 1 giorno, come rete di sicurezza se un job muore a metà.

### SSE-C: non è utilizzabile

Il plugin sa dichiarare **solo due** modalità di cifratura, via
`ansible_aws_ssm_bucket_sse_mode`:

| Valore | Modalità |
|---|---|
| `AES256` | SSE-S3 |
| `aws:kms` | SSE-KMS (+ `ansible_aws_ssm_bucket_sse_kms_key_id`) |

**SSE-C (Server-Side Encryption with Customer-Provided Keys) non è supportato.**
Nel codice del plugin la generazione degli header si ferma a
`x-amz-server-side-encryption` e `x-amz-server-side-encryption-aws-kms-key-id`
(`plugin_utils/ssm/s3clientmanager.py`, funzione `generate_encryption_settings`);
gli header SSE-C — `x-amz-server-side-encryption-customer-algorithm`, `-key`,
`-key-MD5` — non vengono mai emessi, né sul PUT né sul GET.

Quindi, se sul bucket c'è una policy che nega le richieste prive di SSE-C, il
risultato è: **i task `raw` funzionano, ogni modulo Ansible fallisce con 403.**

Nota: SSE-C non è una proprietà del bucket. `PutBucketEncryption` accetta solo
`AES256` e `aws:kms`, perciò "bucket con SSE-C" significa sempre *una bucket
policy che obbliga il client a mandare quegli header*. Il ruolo `ssm_preflight`
legge la policy e si ferma con un messaggio esplicito se la trova.

Le strade praticabili, in ordine di preferenza:

1. **Un bucket di transito dedicato con SSE-KMS.** È la scelta giusta: non è un
   bucket dati, è uno scratch con lifecycle a 1 giorno, e SSE-KMS soddisfa
   "dati cifrati a riposo con chiave gestita dal cliente" quanto SSE-C — in più
   lascia la traccia in CloudTrail di ogni `Decrypt`.
2. **Un prefix esentato nella policy del bucket esistente**, per esempio
   `ansible-transfer/*`, a cui si applica SSE-KMS invece di SSE-C. Funziona se
   il vincolo organizzativo è "cifrato a riposo" e non "cifrato con *quella*
   chiave".
3. **Patchare il plugin.** Sconsigliato, e non solo per il costo di
   manutenzione: con SSE-C la chiave dovrebbe finire nella riga di comando del
   `curl` eseguito sulla VM, quindi visibile nella process list e potenzialmente
   nei log delle sessioni Session Manager. Si peggiorerebbe la postura di
   sicurezza nel tentativo di irrigidirla.

## 2. Il ruolo IAM dell'istanza EC2

All'istanza serve un **instance profile** con la managed policy
`AmazonSSMManagedInstanceCore`. Tanto basta: come spiegato sopra, i
trasferimenti usano presigned URL e la VM non autentica nulla verso S3.

Senza instance profile l'SSM Agent gira ma non si registra mai, e l'istanza non
compare in `aws ssm describe-instance-information`.

> [iam-policy-ec2-instance.json](iam-policy-ec2-instance.json) concede
> all'istanza anche l'accesso diretto al bucket. **Non è richiesto dal plugin**:
> lo lasciamo perché serviva alle versioni vecchie (che usavano `aws s3 cp`
> sulla VM) e perché torna comodo se vuoi usare la AWS CLI dalla macchina. Se
> preferisci il minimo privilegio, non applicarla.

## 3. I permessi del controller AAP

L'identità usata dalla credential *Amazon Web Services* di AAP (utente IAM con
access key, oppure ruolo assunto dai pod dell'Execution Environment) serve per
tre cose: leggere l'inventario EC2, aprire sessioni SSM, usare il bucket. Vedi
[iam-policy-aap-controller.json](iam-policy-aap-controller.json), sostituendo
`BUCKET_NAME`, `REGION` e `ACCOUNT_ID`.

Nota sulla `Condition`: `ssm:StartSession` è ristretto alle istanze con tag
`AnsibleManaged=true`. È lo stesso tag su cui filtra l'inventario dinamico, così
AAP può accedere solo a ciò che effettivamente gestisce.

## Connettività di rete

L'SSM Agent deve raggiungere **in uscita sulla 443** tre endpoint:
`ssm.<region>.amazonaws.com`, `ssmmessages.<region>.amazonaws.com`,
`ec2messages.<region>.amazonaws.com`.

Le opzioni sono due:

- subnet pubblica con IP pubblico / subnet privata con NAT gateway;
- **VPC endpoint di tipo Interface** per `ssm`, `ssmmessages`, `ec2messages`,
  più un **Gateway endpoint per S3** (serve al trasferimento file).

Nessuna porta in ingresso: il security group della demo non ha regole inbound.

## Script

```bash
# Crea bucket, ruoli e policy
./setup-ssm-demo.sh

# ...e anche una SLES 15 di prova, senza chiave SSH
REGION=eu-south-1 ./setup-ssm-demo.sh --with-instance

# Smonta tutto
./setup-ssm-demo.sh --teardown
```

Se il bucket esiste già, passalo allo script: rileva che c'è e si limita ad
allineare block public access, cifratura di default e lifecycle.

```bash
REGION=eu-south-1 BUCKET=aws-aceh-aap-tst-s3-01 ./setup-ssm-demo.sh
```

Lo script si ferma ad aspettare che l'istanza risulti `Online` in SSM: di
norma 2-5 minuti dopo il boot.

## Verifiche manuali rapide

```bash
# L'istanza è registrata?
aws ssm describe-instance-information --region eu-south-1 \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' \
  --output table

# Apri una shell a mano (richiede il session-manager-plugin in locale)
aws ssm start-session --region eu-south-1 --target i-0123456789abcdef0

# Il bucket impone SSE-C? Se compare 'customer-algorithm', il plugin non passa.
aws s3api get-bucket-policy --bucket aws-aceh-aap-tst-s3-01 --region eu-south-1 \
  --query Policy --output text | python3 -m json.tool

# Qual è la default encryption del bucket?
aws s3api get-bucket-encryption --bucket aws-aceh-aap-tst-s3-01 --region eu-south-1

# Prova diretta di PUT senza header SSE-C: è esattamente ciò che fa il plugin.
echo prova > /tmp/prova.txt
aws s3 cp /tmp/prova.txt s3://aws-aceh-aap-tst-s3-01/ansible-transfer/prova.txt \
  --region eu-south-1 && \
  aws s3 rm s3://aws-aceh-aap-tst-s3-01/ansible-transfer/prova.txt --region eu-south-1
```

Se l'ultimo comando restituisce `AccessDenied` mentre le credenziali hanno
`s3:PutObject`, è quasi certamente la policy che pretende SSE-C.
