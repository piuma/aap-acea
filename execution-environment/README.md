# Execution Environment

EE custom con il **`session-manager-plugin`**, che gli EE standard di Red Hat
non contengono. Senza questo binario il connection plugin `aws_ssm` non può
aprire la sessione, e il job fallisce con `Unable to find session-manager-plugin`.

```bash
pip install ansible-builder          # >= 3.0
podman login registry.redhat.io      # per l'immagine base

REGISTRY=quay.io/tua-org PUSH=true IMAGE_TAG=1.0.0 ./build.sh
```

## Tre tranelli, tutti già disinnescati qui

Vale la pena conoscerli, perché si ripresentano su qualsiasi EE custom basato
sulle immagini `ee-minimal`.

### 1. `ansible-builder` presume `dnf`, ma `ee-minimal` ha solo `microdnf`

Le immagini `ee-minimal-rhel9` sono costruite su UBI9-**minimal**, che non
include `dnf`. `ansible-builder` emette `ARG PKGMGR="/usr/bin/dnf"` di default
e lo script `assemble` muore così:

```
+ /usr/bin/dnf install -y rsync
/output/scripts/assemble: line 73: /usr/bin/dnf: No such file or directory
Error: building at STEP "RUN /output/scripts/assemble": exit status 127
```

(`rsync` arriva dal `bindep.txt` di `ansible.posix`, non dal nostro.)

Rimedio, già presente in [execution-environment.yml](execution-environment.yml):

```yaml
options:
  package_manager_path: /usr/bin/microdnf
```

Se cambi immagine base verso una UBI9 "piena" o verso `quay.io/ansible/awx-ee`
(CentOS Stream), rimetti `/usr/bin/dnf`.

### 2. Niente direttive `USER` in `additional_build_steps`

`ansible-builder` avvisa, e ha ragione. Lo stage finale **gira già come root**
— il Containerfile generato ha `USER root` subito dopo il `FROM` dell'immagine
base — e rimette `USER 1000` in fondo. Un `USER 1000` messo in `append_final`
finisce *prima* del `RUN rm -rf /output` generato da ansible-builder, che
girerebbe senza privilegi su una directory di root e farebbe fallire la build.

Quindi: niente `USER root` (inutile) e niente `USER 1000` (dannoso).

### 3. L'indentazione negli scalari YAML `>-` spezza i `RUN`

In un blocco `>-` gli a capo diventano spazi **solo** se tutte le righe hanno
la stessa indentazione. Una riga più indentata è una *more-indented line* e
conserva il newline. Questo:

```yaml
- >-
  RUN ... && ln -sf /usr/local/sessionmanagerplugin/bin/session-manager-plugin
            /usr/local/bin/session-manager-plugin
```

produce un `RUN` spezzato su tre righe fisiche del Containerfile, senza
continuazioni: la build si rompe in modo incomprensibile.

## Verificare prima di costruire

`ansible-builder create` genera il contesto senza costruire nulla: è il modo
più rapido per guardare cosa verrà eseguito davvero.

```bash
ansible-builder create --file execution-environment.yml --context /tmp/ctx
grep -n 'ARG PKGMGR=' /tmp/ctx/Containerfile      # deve dire microdnf
tail -15 /tmp/ctx/Containerfile                    # controlla USER e i RUN
```

Lo step di installazione del plugin è stato provato su un container
`ubi9/ubi-minimal` reale: `curl` + `rpm -Uvh --nodeps` installano
`session-manager-plugin` 1.2.896.0, il symlink `/usr/local/bin/` è corretto e
il binario resta eseguibile da uid 1000, che è l'utente con cui girano gli EE.

## File

| File | Contenuto |
|---|---|
| [execution-environment.yml](execution-environment.yml) | Definizione ansible-builder v3 |
| [requirements.yml](requirements.yml) | Collection incluse nell'immagine |
| [requirements.txt](requirements.txt) | `boto3`, `botocore`, `jmespath` |
| [bindep.txt](bindep.txt) | Pacchetti di sistema (non dichiarare `curl`: su UBI9 c'è `curl-minimal` e andrebbe in conflitto) |
| [build.sh](build.sh) | Build, verifica del contenuto dell'immagine, push opzionale |
