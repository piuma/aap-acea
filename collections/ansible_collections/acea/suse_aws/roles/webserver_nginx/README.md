# `acea.suse_aws.webserver_nginx`

Installa nginx su SUSE Linux Enterprise e pubblica una pagina di benvenuto che
mostra i fact dell'host. Esempio di ruolo idempotente con percorso di rimozione
completo.

Richiede `gather_facts: true` nel play.

## Variabili

| Variabile | Default | Note |
|---|---|---|
| `webserver_nginx_state` | `present` | `absent` rimuove vhost, docroot, regola firewall e pacchetto |
| `webserver_nginx_package` | `nginx` | |
| `webserver_nginx_service` | `nginx` | |
| `webserver_nginx_port` | `80` | |
| `webserver_nginx_docroot` | `/srv/www/htdocs/aap-demo` | Path SUSE |
| `webserver_nginx_site_name` | `aap-demo` | Nome del file in `/etc/nginx/conf.d/` |
| `webserver_nginx_site_title` | `AAP demo` | Titolo della pagina |
| `webserver_nginx_owner` | `Team Automazione` | Referente mostrato in pagina |
| `webserver_nginx_default_server` | `true` | Vedi nota sotto |
| `webserver_nginx_manage_firewall` | `true` | Agisce solo se firewalld è in esecuzione |
| `webserver_nginx_firewall_zone` | `public` | |

## Esempio

```yaml
- hosts: suse_servers
  gather_facts: true
  roles:
    - role: acea.suse_aws.webserver_nginx
      vars:
        webserver_nginx_site_title: "Demo ACEA"
```

## Note

- Il vhost è dichiarato `default_server`. Se l'immagine SLES ha già un
  `default_server` in `/etc/nginx/nginx.conf`, `nginx -t` fallisce in fase di
  `validate`: imposta `webserver_nginx_default_server: false`.
- Il ruolo espone `/healthz`, usato dal playbook `acea.suse_aws.webserver` per
  la verifica funzionale.
- La porta non è esposta a Internet. Per raggiungerla dal tuo portatile usa il
  port forwarding di Session Manager (il playbook lo stampa a fine run).
