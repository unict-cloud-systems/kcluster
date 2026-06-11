### VARIABILI DA CONFIGURARE (vedi sezioni ##)          ###
### Verificare righe bene ## #
### ATTENZIONE, in "V=DEF" NO SPAZI PRIMA E DOPO "="    ###


## Definizioni per cluster dei nodi kubernetes

KHOSTS_NETWORK=192.168.55.0/24

## nomi con cui sono noti in k8s gli host del cluster e loro IP nel cluster k8s
## config.sh e' autoritativo: questi sono gli IP stabili usati dagli script e da Kubernetes.
## Con Multipass, cloud-init aggiunge questi IP come alias sulla NIC primaria delle VM.
## Il client deve avere una route verso KHOSTS_NETWORK via bridge Multipass.
#KHOSTS[x1]=192.168.252.12
#KHOSTS[x2]=192.168.252.13
#KHOSTS[x3]=192.168.252.14
#KHOSTS[x4]=192.168.252.15

KHOSTS[s0]=192.168.55.70
KHOSTS[s1]=192.168.55.71
KHOSTS[s2]=192.168.55.72
KHOSTS[s3]=192.168.55.73
#KHOSTS[s12]=192.168.45.72
#KHOSTS[s4]=192.168.45.64

# i nomi possono essere quelli ufficiali degli host del
# cluster o possono essere inventati e introdotti qui

#KHOSTS[z1]=192.168.252.59
#KHOSTS[z2]=192.168.252.60
#KHOSTS[z3]=192.168.252.41
#KHOSTS[z4]=192.168.252.42

## Definizioni rete dei Pod e dei servizi

POD_NETWORK_CIDR="10.10.0.0/16"
# blocco di IP allocato per la rete dei Pod

SERVICE_CIDR="172.96.0.0/16"
# blocco CIDR allocato per gli IP "virtuali" dei servizi

## Quale container engine usa il cluster?
CONTAINER_RUNTIME=containerd
#CONTAINER_RUNTIME=crio


## KUSER e KEYFILE

#KUSER=myself
#KUSER=vagrant
KUSER=ubuntu      # default più ragionevole, ma verificare sia presente sui nodi del cluster
## si presume che su ognuno degli host del cluster vi sia l'utente $KUSER,
## con home directory con lo stesso nome, che utilizzera` k8s
## KUSER deve poter eseguire sudo SENZA PASSWORD (NOPASSWD) su tutti i nodi.
## Le VM Ubuntu standard (EC2, multipass, vagrant) lo garantiscono per default per l'utente ubuntu.

# su ciascun host $KUSER avra` la chiave privata $KEYFILE
# (ci pensa lo script )

## KEYFILE (obbligatoria): chiave privata ssh usata dal cliente verso i nodi,
## e caricata sui nodi (IdentityFile in xhosts_ssh_config) per ssh fra nodi.
## Usare una chiave dedicata al progetto, NON quella personale (~/.ssh/id_*).
## Pathname di KEYFILE assoluto o relativo (i relativi sono cercati in ./ e ../).
## Se serve, generarne una (senza passphrase, commento "k8s"):
##   ssh-keygen -t rsa -N '' -C 'k8s' -f xhosts_key.pem
KEYFILE=xhosts_key.pem            # il default più ragionevole
#KEYFILE=multipass_key.pem        # se si usa multipass
#KEYFILE=../keys/xhosts_key.pem   # se le chiavi sono fuori da questa directory

### FINE VARIABILI DA CONFIGURARE                   ###
