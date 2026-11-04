# Perché `group_vars` sta qui dentro

Ansible carica `group_vars/` da due posti: la directory che contiene il file di
inventario e la directory che contiene il playbook. Dato che i playbook stanno
in [playbooks/](../../playbooks/), mettere `group_vars/` nella root del repo
**non** funzionerebbe: va accanto all'inventario.

In AAP valgono le stesse regole al momento dell'`inventory sync`: le variabili
definite qui vengono importate come variabili di gruppo dell'Inventory.

Se preferisci gestirle dalla UI, puoi cancellare questi file e incollare lo
stesso contenuto in **Inventories > \<inventory\> > Groups > suse_servers >
Variables**.
