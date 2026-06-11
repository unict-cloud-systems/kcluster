# kcluster

Script didattici per creare, installare, resettare e avviare un cluster
Kubernetes con `kubeadm` su host Ubuntu.

Il progetto è pensato per laboratorio e apprendimento: espone i passaggi che
tool più maturi automatizzano o nascondono. Non è un sostituto di Kubespray,
Cluster API, Rancher, OpenShift, Terraform/Ansible o di un processo production
grade.

## TL;DR (Quick start)

Modificare `config.sh`, in particolare:

- `KHOSTS_NETWORK`: rete IP dei nodi;
- `KHOSTS[...]`: nomi e IP stabili dei nodi;
- `POD_NETWORK_CIDR`: rete dei Pod;
- `SERVICE_CIDR`: rete dei Service;
- `KUSER`: utente remoto sui nodi;
- `KEYFILE`: chiave SSH di progetto;
- `CONTAINER_RUNTIME`: `containerd` o `crio`.

Se si usa Multipass, creare le VM:

```bash
./mp_kcluster_launch.sh
```

Poi, sul client, da `bash`:

```bash
. ./set_env.sh
./upload_kcluster_setup.sh -y
. ./set_env.sh -f
```

Su ogni nodo, come root:

```bash
sudo -i
cd /home/<KUSER>/setup_kube
./install_kube.sh
```

Avvio manuale:

```bash
# sul master
./boot_master.sh

# sui worker, dopo il master
./boot_worker.sh
```

Oppure, dal client dopo `. ./set_env.sh`:

```bash
all_boot <master-node>
get_kconf
kubectl get nodes
```

Per resettare e ricreare il cluster:

```bash
all_reset
all_boot <master-node>
```

Per operare su più nodi insieme:

```bash
sshx $NODES
sshx $NODES -s0   # s0 in finestra master separata
```

## Indice

- [TL;DR (Quick start)](#tldr-quick-start)
- [Idea generale](#idea-generale)
- [Prerequisiti](#prerequisiti)
- [Quick start con Multipass](#quick-start-con-multipass)
- [Quick start con host già esistenti](#quick-start-con-host-già-esistenti)
- [Configurazione](#configurazione)
- [Rete e indirizzi](#rete-e-indirizzi)
- [Ambiente client](#ambiente-client)
- [Upload, zip e file distribuiti](#upload-zip-e-file-distribuiti)
- [Installazione sui nodi](#installazione-sui-nodi)
- [Avvio e reset del cluster](#avvio-e-reset-del-cluster)
- [Multipass: cosa fa lo script](#multipass-cosa-fa-lo-script)
- [Template e file generati](#template-e-file-generati)
- [Versioni e componenti](#versioni-e-componenti)
- [Transcript didattico](#transcript-didattico)
- [File principali](#file-principali)
- [Troubleshooting](#troubleshooting)

## Idea generale

`config.sh` è la fonte di verità del cluster:

- nomi dei nodi;
- IP stabili dei nodi, tramite `KHOSTS[...]`;
- rete dei nodi, tramite `KHOSTS_NETWORK`;
- rete Pod e rete Service;
- utente remoto (`KUSER`);
- chiave SSH di progetto (`KEYFILE`);
- container runtime scelto.

Il flusso è:

1. definire `config.sh`;
2. creare o rendere raggiungibili gli host agli IP `KHOSTS`;
3. sorgere l'ambiente client con `. ./set_env.sh`;
4. caricare gli script sui nodi con `./upload_kcluster_setup.sh -y`;
5. installare Kubernetes sui nodi con `install_kube.sh`;
6. avviare il master con `boot_master.sh`;
7. unire i worker con `boot_worker.sh`.

Con Multipass, il passo 2 è gestito da `mp_kcluster_launch.sh`: crea le VM,
renderizza `cloud-init`, aggiunge sugli host guest gli alias IP definiti in
`config.sh`, e aggiunge sul client una route verso `KHOSTS_NETWORK`.

## Prerequisiti

Sul client:

- `bash`;
- `ssh`, `scp`, `rsync`;
- `tmux`, se si usa `sshx`;
- `zip`, se si usa `./upload_kcluster_setup.sh --zip`;
- `multipass`, solo per il flusso Multipass;
- connettività IP verso tutti gli indirizzi `KHOSTS`.

Sui nodi:

- Ubuntu o derivata con `systemd`, `apt`, `sudo`;
- utente `$KUSER` già esistente;
- `$KUSER` sudoer senza password (`NOPASSWD`);
- accesso Internet ai repository Docker, Kubernetes e CRI-O durante
  `install_kube.sh`;
- host dedicati o VM sacrificabili: `reset_kube.sh` distrugge lo stato
  Kubernetes locale.

La chiave privata indicata da `KEYFILE` viene caricata sui nodi per permettere
SSH tra nodi. Usare una chiave dedicata al laboratorio, senza passphrase, non
una chiave personale.

```bash
ssh-keygen -t rsa -N '' -C 'k8s' -f xhosts_key.pem
```

## Quick start con Multipass

Modificare `config.sh`, in particolare:

```bash
KHOSTS_NETWORK=192.168.55.0/24
KHOSTS[s0]=192.168.55.70
KHOSTS[s1]=192.168.55.71
KHOSTS[s2]=192.168.55.72
KHOSTS[s3]=192.168.55.73
KUSER=ubuntu
KEYFILE=xhosts_key.pem
CONTAINER_RUNTIME=containerd
```

Generare la chiave, se manca:

```bash
ssh-keygen -t rsa -N '' -C 'k8s' -f xhosts_key.pem
```

Creare le VM Multipass:

```bash
./mp_kcluster_launch.sh
```

Lo script è idempotente:

- se tutti gli IP `KHOSTS` rispondono, non modifica nulla;
- se nessun IP risponde e non esistono VM Multipass con quei nomi, crea le VM;
- se trova una situazione parziale, si ferma e chiede di ripulire.

Poi aprire `bash` e sorgere l'ambiente client:

```bash
bash
. ./set_env.sh
```

Su un cluster appena creato, è normale che `set_env.sh` segnali che sugli host
mancano ancora i file di setup. Caricarli:

```bash
./upload_kcluster_setup.sh -y
```

Per completare anche l'aggiornamento remoto di `/etc/hosts` dopo il primo
upload:

```bash
. ./set_env.sh -f
```

Installare Kubernetes su tutti i nodi. Il modo più comodo è aprire una
sessione `tmux` con pane sincronizzati:

```bash
sshx $NODES
```

Su tutti i nodi:

```bash
sudo -i
cd /home/ubuntu/setup_kube
./install_kube.sh
```

`install_kube.sh` termina invocando `reset_kube.sh`, quindi i nodi sono pronti
per il boot del cluster.

Per il boot può essere più comodo aprire una nuova sessione con il master in
una finestra tmux dedicata:

```bash
sshx $NODES -s0
```

Nell'esempio sopra `s0` sarà il master.

Nel pane/finestra del master:

```bash
./boot_master.sh
```

Nei pane dei worker:

```bash
./boot_worker.sh
```

Dal client, dopo che il cluster è su:

```bash
get_kconf
kubectl get nodes
```

## Quick start con host già esistenti

Usare questo flusso per AWS, Vagrant, bare metal o VM già create.

Prima creare/configurare gli host in modo che:

- gli IP corrispondano a `KHOSTS[...]` in `config.sh`;
- il client li raggiunga direttamente, ad esempio via VPN o LAN privata;
- `$KUSER` esista su ogni nodo;
- `$KUSER` abbia sudo `NOPASSWD`;
- la chiave pubblica `${KEYFILE}.pub` sia autorizzata per `$KUSER`, oppure
  l'host permetta login iniziale via password per farla installare a
  `set_env.sh`.

Poi:

```bash
bash
. ./set_env.sh
./upload_kcluster_setup.sh -y
. ./set_env.sh -f
```

Infine, sugli host:

```bash
sudo -i
cd /home/<KUSER>/setup_kube
./install_kube.sh
./boot_master.sh      # solo sul futuro master
./boot_worker.sh      # sui worker, dopo il master
```

In alternativa, dopo upload e installazione, il client può avviare tutto:

```bash
all_boot <master-node>
```

## Configurazione

Le variabili da modificare stanno in `config.sh`.

| Variabile | Significato |
|---|---|
| `KHOSTS_NETWORK` | Rete IP stabile dei nodi Kubernetes, es. `192.168.55.0/24` |
| `KHOSTS[name]=ip` | Mappa nome nodo -> IP stabile |
| `POD_NETWORK_CIDR` | CIDR della rete Pod, usato dal CNI |
| `SERVICE_CIDR` | CIDR virtuale dei Service Kubernetes |
| `CONTAINER_RUNTIME` | Runtime usato da kubelet: `containerd` o `crio` |
| `KUSER` | Utente remoto previsto su tutti i nodi |
| `KEYFILE` | Chiave privata SSH di progetto |
| `MASTER_NODE` | Opzionale: master predefinito per `all_boot` da client esterno |

I nomi in `KHOSTS` diventano i nomi nodo Kubernetes (`--node-name` in
`kubeadm`). Tenere nomi corti e stabili, per esempio `s0 s1 s2 s3`.

## Rete e indirizzi

Gli script assumono tre reti concettualmente distinte:

- `KHOSTS_NETWORK`: rete dei nodi, usata da SSH e da Kubernetes per parlare
  con gli host;
- `POD_NETWORK_CIDR`: rete interna dei Pod;
- `SERVICE_CIDR`: rete virtuale dei Service Kubernetes.

`KHOSTS_NETWORK` è deliberatamente definita in `config.sh`, così lo stesso
file resta fonte unica sia su cloud/on-prem sia in laboratorio locale.

Con AWS, Vagrant o bare metal, normalmente gli host hanno già gli IP previsti.
Con Multipass su macOS/Linux, invece, gli IP NAT assegnati da Multipass non sono
controllabili in modo affidabile; per questo `cloud-init` aggiunge alle VM un
alias IP sulla NIC primaria, prendendolo da `KHOSTS`.

Sul client deve esistere una route verso `KHOSTS_NETWORK`. Con Multipass,
`mp_kcluster_launch.sh` prova ad aggiungerla automaticamente e avvisa prima di
usare `sudo`.

## Ambiente client

`set_env.sh` deve essere sorgente da `bash`:

```bash
bash
. ./set_env.sh
```

Non va eseguito direttamente e non va sorgente da `zsh`.

Azioni principali:

- legge `config.sh` tramite `set_vars.sh`;
- genera `xhosts_ssh_config`;
- definisce funzioni bash `ssh` e `scp` che usano automaticamente quella
  configurazione;
- esporta `SSHOPTS`;
- copia la chiave pubblica sui nodi, se serve;
- verifica `sudo -n true` per `$KUSER`;
- aggiorna `/etc/hosts` remoti quando i file di setup sono già presenti;
- carica funzioni operative (`all_boot`, `all_reset`, `sshx`, ecc.).

Opzioni:

```bash
. ./set_env.sh -f   # forza setup remoto chiavi/hosts
. ./set_env.sh -l   # solo ambiente locale, niente setup remoto
. ./set_env.sh -r   # reset/undefine del solo ambiente locale
```

Dopo `. ./set_env.sh`, per usare il binario SSH vero invece della funzione:

```bash
command ssh ...
command scp ...
```

Funzioni disponibili:

| Funzione | Uso |
|---|---|
| `ssh host` | SSH verso un nodo usando `xhosts_ssh_config` |
| `scp ...` | SCP usando la stessa configurazione |
| `sshx host1 host2 ... [-master]` | Avvia tmux con pane SSH sincronizzati |
| `all_nodes <cmd>` | Esegue un comando su tutti i nodi |
| `all_boot [master] [-q]` | Avvia master e worker |
| `all_reset [-q]` | Resetta tutti i nodi, master per ultimo |
| `get_master` | Trova il master corrente interrogando Kubernetes |
| `get_kconf` | Copia la kubeconfig del master in `~/.kube/config` |
| `k8s_setup_hints` | Mostra checklist estesa dei prerequisiti |

## Upload, zip e file distribuiti

Uso principale:

```bash
./upload_kcluster_setup.sh -y
```

Dry-run:

```bash
./upload_kcluster_setup.sh -n
./upload_kcluster_setup.sh --dry-run-send-to-khosts
```

Zip locale:

```bash
./upload_kcluster_setup.sh --zip
```

L'upload verso i nodi include:

- `README.md`;
- `config.sh`;
- `set_vars.sh`;
- `set_env.sh`;
- `upload_kcluster_setup.sh`;
- `install_kube.sh`;
- `reset_kube.sh`;
- `boot_master.sh`;
- `boot_worker.sh`;
- `_scripts/`;
- `_templates/`;
- `KEYFILE` e `${KEYFILE}.pub`, se presenti.

Non vengono caricati sui nodi:

- `mp_kcluster_launch.sh`, perchè è solo client-side;
- `_generated/`;
- zip locali;
- file storici o backup locali.

Lo zip include il set distribuibile più `mp_kcluster_launch.sh`, ma non include
le chiavi SSH.

## Installazione sui nodi

Da root, su ogni nodo:

```bash
sudo -i
cd /home/<KUSER>/setup_kube
./install_kube.sh
```

`install_kube.sh`:

- installa utilità base;
- configura repository Docker, Kubernetes e CRI-O;
- installa `containerd.io`;
- installa `cri-o`;
- installa `kubelet`, `kubeadm`, `kubectl`;
- genera configurazioni `crictl`;
- configura moduli e sysctl richiesti da Kubernetes;
- installa completion bash per `kubeadm`, `kubectl`, `crictl`;
- installa `.inputrc` per root e `$KUSER`;
- chiama `reset_kube.sh` alla fine.

L'installazione può essere rilanciata, ma è pensata come passo raro: serve
quando si prepara un nodo nuovo o si vogliono aggiornare componenti di sistema.

## Avvio e reset del cluster

Reset manuale di un nodo:

```bash
sudo -i
cd /home/<KUSER>/setup_kube
./reset_kube.sh
```

`reset_kube.sh` ferma lo stato Kubernetes locale, invoca `kubeadm reset -f`,
pulisce CNI e configurazioni locali, aggiorna `/etc/hosts` e lascia il nodo
pronto per un nuovo boot.

Avvio manuale:

```bash
# sul futuro master
sudo -i
cd /home/<KUSER>/setup_kube
./boot_master.sh

# sui worker, dopo il master
sudo -i
cd /home/<KUSER>/setup_kube
./boot_worker.sh
```

`boot_master.sh` esegue `kubeadm init`, copia la kubeconfig in `/root/.kube` e
`/home/$KUSER/.kube`, genera `/joincluster.sh` e `/tmp/joincluster.sh`, poi
renderizza e applica Calico.

`boot_worker.sh` recupera `/tmp/joincluster.sh` dagli altri nodi tramite rsync,
aggiunge `--node-name $THISNODE`, poi esegue il join.

Avvio da client:

```bash
all_boot s0
```

Se `MASTER_NODE=s0` è definito in `config.sh` o nella shell:

```bash
all_boot
```

Reset completo da client:

```bash
all_reset
```

Recupero kubeconfig sul client:

```bash
get_kconf
kubectl get nodes
```

## Multipass: cosa fa lo script

`mp_kcluster_launch.sh` va eseguito prima di `. ./set_env.sh`.

```bash
./mp_kcluster_launch.sh
```

Sizing custom:

```bash
CPUS=4 MEM=4G DISK=20G IMAGE=24.04 ./mp_kcluster_launch.sh
```

Dry-run:

```bash
./mp_kcluster_launch.sh --dry-run
```

Lo script:

1. legge `config.sh`;
2. verifica se gli IP `KHOSTS` rispondono;
3. se il cluster è già raggiungibile, esce senza modificare nulla;
4. se lo stato è parziale, abortisce;
5. renderizza `_generated/cloud_init.yaml`;
6. crea le VM Multipass;
7. attende `cloud-init`;
8. verifica che gli alias `KHOSTS` siano presenti dentro le VM;
9. aggiunge sul client la route verso `KHOSTS_NETWORK`.

Se `cloud-init` fallisce, lo script si ferma al primo nodo fallito e suggerisce
di eliminare le VM, correggere `_templates/cloud_init.yaml`, e ripartire:

```bash
multipass delete --purge s0 s1 s2 s3
./mp_kcluster_launch.sh
```

Comandi diagnostici utili:

```bash
multipass exec s0 -- sudo cloud-init status --long
multipass exec s0 -- sudo tail -200 /var/log/cloud-init-output.log
multipass exec s0 -- sudo tail -200 /var/log/cloud-init.log
```

## Template e file generati

I template versionati stanno in `_templates/`.

File principali:

- `_templates/cloud_init.yaml`;
- `_templates/cloud_init.inputrc`;
- `_templates/cloud_init.motd.sh`;
- `_templates/setup-kube-netplan.sh`;
- `_templates/calico.yaml`;
- `_templates/flannel.yml`;
- `_templates/containerd-net.conflist`;
- `_templates/crictl.runtime.yaml`;
- `_templates/crictl.yaml`;
- `_templates/metrics-server.yaml`;
- `_templates/rdate-hwclock.sh`.

Il renderer è:

```bash
_scripts/render_template.sh
```

Esempi:

```bash
_scripts/render_template.sh --cloud-init --output _generated/cloud_init.yaml
_scripts/render_template.sh --calico --output _generated/calico-10.10.0.0_16.yaml
_scripts/render_template.sh --flannel --output _generated/flannel-10.10.0.0_16.yml
```

I file generati stanno in `_generated/` e non sono parte del pacchetto
pubblico/distribuito.

## Versioni e componenti

`install_kube.sh` installa:

- `containerd.io`;
- `cri-o`;
- `kubelet`;
- `kubeadm`;
- `kubectl`;
- `crictl`;
- utilità di supporto (`curl`, `gnupg`, `rsync`, `lsof`, ecc.).

La versione Kubernetes è definita in `install_kube.sh`:

```bash
VERSION_K8S=1.33
```

Il runtime usato da kubelet è scelto in `config.sh`:

```bash
CONTAINER_RUNTIME=containerd
#CONTAINER_RUNTIME=crio
```

Il CNI applicato automaticamente è Calico, renderizzato da
`_templates/calico.yaml` con il `POD_NETWORK_CIDR` configurato.

## Transcript didattico

`boot_master.sh` e `boot_worker.sh` possono generare un transcript dei comandi
amministrativi principali.

```bash
K8S_SETUP_TRANSCRIPT=1 ./boot_master.sh
K8S_SETUP_TRANSCRIPT=1 ./boot_worker.sh
```

Producono file come:

```text
/root/k8s-setup-<node>-boot_master.transcript
/root/k8s-setup-<node>-boot_worker.transcript
```

Con livello 2:

```bash
K8S_SETUP_TRANSCRIPT=2 ./boot_master.sh
K8S_SETUP_TRANSCRIPT=2 ./boot_worker.sh
```

mostra il transcript anche a terminale e salva l'output grezzo in:

```text
/root/k8s-setup-<node>-boot_master.raw.log
/root/k8s-setup-<node>-boot_worker.raw.log
```

Il transcript è generato dai marker `#@` dentro gli script; serve a mostrare
quali azioni farebbe a mano un amministratore Kubernetes.

## File principali

| File/directory | Ruolo |
|---|---|
| `config.sh` | Configurazione cluster |
| `set_vars.sh` | Calcola variabili derivate, colori, mapping nodi/IP |
| `set_env.sh` | Ambiente client e setup remoto chiavi/hosts |
| `upload_kcluster_setup.sh` | Zip/upload verso i nodi |
| `mp_kcluster_launch.sh` | Creazione cluster Multipass |
| `install_kube.sh` | Installazione pacchetti e prerequisiti sui nodi |
| `reset_kube.sh` | Reset locale Kubernetes/CNI/runtime |
| `boot_master.sh` | `kubeadm init` e deploy CNI |
| `boot_worker.sh` | Join worker al cluster |
| `_scripts/` | Funzioni comuni, renderer, transcript |
| `_templates/` | Template versionati |
| `_generated/` | File generati localmente, non distribuiti |

## Troubleshooting

### `. ./set_env.sh` dice che è stato sorgente da zsh

Aprire una shell bash:

```bash
bash
. ./set_env.sh
```

### `KEYFILE` o `${KEYFILE}.pub` mancano

Generarli o correggere `KEYFILE` in `config.sh`:

```bash
ssh-keygen -t rsa -N '' -C 'k8s' -f xhosts_key.pem
```

### Nessun nodo risponde a ping

Verificare:

- IP in `KHOSTS[...]`;
- route/VPN dal client verso `KHOSTS_NETWORK`;
- VM o host accesi;
- con Multipass, eseguire o rieseguire `./mp_kcluster_launch.sh`.

### Alcuni nodi rispondono e altri no

Lo stato è incoerente. Con Multipass conviene spesso ripulire e ricreare:

```bash
multipass delete --purge s0 s1 s2 s3
./mp_kcluster_launch.sh
```

### `set_env.sh` fallisce per sudo

`$KUSER` deve poter eseguire `sudo -n true`. Correzione tipica sul nodo, da
root:

```bash
echo '<KUSER> ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-<KUSER>-nopasswd
chmod 440 /etc/sudoers.d/99-<KUSER>-nopasswd
```

### `upload_kcluster_setup.sh` dice che SSH non raggiunge tutti i nodi

Prima completare il setup chiavi/hosts:

```bash
. ./set_env.sh -f
```

Se gli host sono appena stati creati, può essere normale dover prima caricare
i file:

```bash
./upload_kcluster_setup.sh -y
```

### `boot_worker.sh` non trova `/joincluster.sh`

Il master non è stato avviato correttamente o il worker non riesce a recuperare
`/tmp/joincluster.sh` dal master. Avviare prima:

```bash
./boot_master.sh
```

poi rieseguire sui worker:

```bash
./boot_worker.sh
```

### Il join fallisce dopo molto tempo

I token `kubeadm` scadono. Rigenerare il master boot, o resettare e riavviare:

```bash
all_reset
all_boot <master-node>
```

### `kubeadm reset` sembra bloccato

`reset_kube.sh` usa un timeout e una pulizia manuale di fallback. Se il blocco
persiste, controllare i mount sotto `/var/lib/kubelet` e la directory
`/etc/cni/net.d`, come indicato dallo script.

### Dopo modifiche locali gli host usano ancora file vecchi

Ricaricare:

```bash
./upload_kcluster_setup.sh -y
```

Se è cambiato `config.sh`, forzare anche:

```bash
. ./set_env.sh -f
```

### Stato remoto pubblico

Il branch pubblico è pensato per contenere solo i file operativi e i template.
Non pubblicare chiavi SSH, `_generated/`, `_kube/`, zip locali, backup o file di
lavoro personali.
