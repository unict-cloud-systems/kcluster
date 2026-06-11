#!/usr/bin/env bash

. ./set_vars.sh > /dev/null

#CONFIGF=/etc/kubernetes/admin.conf
#per leggere precedente file serve sudo

CONFIGF=$HOME/.kube/config
CONFIGFNEW=$HOME/.kube/config.3
FILES3="ca.crt client.crt client.key"
KUBE_CONF_DIR=$HOME/.kube
mkdir -p $KUBE_CONF_DIR

if [[ $1 != create ]] && [[ $1 != clean ]] ; then
    echo -e "Usage: ${RIT}$0 create|clean${NC}"
    echo -e "Purpose:  assuming ${RIT}$CONFIGF${NC} is a valid configuration file, this script "
    echo -e "          creates a valid equivalent configuration file ${RIT}${CONFIGFNEW}${NC}, which"
    echo -e "          has no explicit certificate or key data, but refers to three "
    echo -e "          certificate/key files ${RIT}ca.crt${NC}, ${RIT}client.crt${NC}, ${RIT}client.key${NC}; these will"
    echo -e "          also be created in ${RIT}$KUBE_CONF_DIR${NC}"
    exit
fi

if [[ ! -f $CONFIGF ]] ; then
    echo -e "${RIT}$CONFIGF${NC} absent, cannot run, maybe change ${RIT}\$CONFIGF${NC}?" 1>&2 
    exit
fi

if [[ $1 == clean ]] ; then
for f in $FILES3 ; do
    rm -f $KUBE_CONF_DIR/$f
done
rm -f $CONFIGFNEW
CMD="ls --color=auto $KUBE_CONF_DIR"
echo $CMD
$CMD
exit
fi

echo -e "extracting k8s certs/key to $FILES3 in $KUBE_CONF_DIR \n"

KEY=certificate-authority-data ; grep $KEY $CONFIGF | sed -e 's/\s*'$KEY':\s*//' | base64 -d > $KUBE_CONF_DIR/ca.crt
echo -n 'fatto: '; ls $KUBE_CONF_DIR/ca.crt
KEY=client-certificate-data ; grep $KEY $CONFIGF | sed -e 's/\s*'$KEY':\s*//' | base64 -d > $KUBE_CONF_DIR/client.crt
echo -n 'fatto: '; ls $KUBE_CONF_DIR/client.crt
KEY=client-key-data ; grep $KEY $CONFIGF | sed -e 's/\s*'$KEY':\s*//' | base64 -d > $KUBE_CONF_DIR/client.key
echo -n 'fatto: '; ls  $KUBE_CONF_DIR/client.key

# Oppure (ma presuppone che k8s abbia gia` una configurazione o "kubectl config view --minify" non funzionerebbe)

#kubectl config view --minify --raw --output 'jsonpath={..user.client-certificate-data}' | base64 -d > $KUBE_CONF_DIR/client.crt
#kubectl config view --minify --raw --output 'jsonpath={..cluster.certificate-authority-data}' | base64 -d > $KUBE_CONF_DIR/ca.crt
#kubectl config view --minify --raw --output 'jsonpath={..user.client-key-data}' | base64 -d > $KUBE_CONF_DIR/client.key

echo -e "\nwriting $CONFIGFNEW\n"

# Per kubectl config view  basta che esista ~/.kube/config
kubectl config view  --output yaml |\
sed -e 's=certificate-authority-data: DATA+OMITTED=certificate-authority: '$KUBE_CONF_DIR'/ca.crt=' \
    -e 's=client-certificate-data: DATA+OMITTED=client-certificate: '$KUBE_CONF_DIR'/client.crt=' \
    -e 's=client-key-data: DATA+OMITTED=client-key: '$KUBE_CONF_DIR'/client.key=' > $CONFIGFNEW
# previously "REDACTED" in lieu of "DATA+OMITTED"

echo -e "Ora puoi usare:  ${RIT}kubectl --kubeconfig $CONFIGFNEW${NC} ... o definire
${RIT}export KUBECONFIG=$CONFIGFNEW${NC}

Nel file ${RIT}$CONFIGNEW${NC} dovrebbero esserci gia' le righe:${RIT}
    certificate-authority: $KUBE_CONF_DIR/ca.crt
    client-certificate: $KUBE_CONF_DIR/client.crt
    client-key: $KUBE_CONF_DIR/client.key${NC}
"
