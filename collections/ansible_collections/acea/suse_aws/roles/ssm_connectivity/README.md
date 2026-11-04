# `acea.suse_aws.ssm_connectivity`

Smoke test della connessione `aws_ssm` verso un host SUSE. Non modifica nulla.

Verifica quattro cose che falliscono per motivi diversi:

- `raw` senza `become` → mostra l'utente della sessione Session Manager
  (`ssm-user`, perché il plugin ignora `remote_user` / `ansible_user`);
- `raw` con `become` → verifica che il sudoers di `ssm-user` sia a posto;
- presenza di `curl` → il plugin fa scaricare i moduli alla VM con `curl` a
  partire da un presigned URL S3: senza, funziona solo `raw`;
- `ansible.builtin.ping` → esercita il **trasferimento del modulo attraverso il
  bucket S3**. Se i `raw` passano e il `ping` no, il problema è il bucket
  (permessi IAM dell'identità di AAP, oppure una policy che impone SSE-C).

Il play che lo include può usare `gather_facts: false`: il ruolo legge
`/etc/os-release` con `slurp`.

## Variabili

| Variabile | Default | Note |
|---|---|---|
| `ssm_connectivity_require_suse` | `true` | Fallisce se l'host non è SUSE |
| `ssm_connectivity_test_module_transfer` | `true` | Esegue il `ping` |

## Esempio

```yaml
- hosts: suse_servers
  gather_facts: false
  roles:
    - role: acea.suse_aws.ssm_connectivity
```
