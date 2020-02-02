#! /usr/bin/env bash

# enable unofficial bash strict mode
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# make script trace visible via `kubectl logs`
set -o xtrace

ALL_DB_SIZE_QUERY="select sum(pg_database_size(datname)::numeric) from pg_database;"
LIST_DB_QUERY='SELECT datname FROM pg_database WHERE datistemplate = false;'
PG_BIN=$PG_DIR/$PG_VERSION/bin
DUMP_SIZE_COEFF=5
VERSION=2

TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
K8S_API_URL=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1
CERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

if [[ -f "/etc/backup/envvars" ]]; then
  set -a
  source "/etc/backup/envvars"
  set +a
fi

function list_databases {
    "$PG_BIN"/psql -tqAc "${LIST_DB_QUERY}"
}

function estimate_size {
    "$PG_BIN"/psql -tqAc "${ALL_DB_SIZE_QUERY}"
}

function dump {
    # settings are taken from the environment
    "$PG_BIN"/pg_dumpall
}

function dumpglobals {
    # settings are taken from the environment
    "$PG_BIN"/pg_dumpall --globals-only
}

function dumpdb {
    declare -r DB="$1"
    # settings are taken from the environment
    "$PG_BIN"/pg_dump -Fc "$DB"
}

function compress {
    pigz
}

function encrypt {
  if [[ -n "$SALTLICK_PUBLIC_KEY" ]]; then
    saltlick encrypt -p "$SALTLICK_PUBLIC_KEY"
  else
    cat
  fi
}

function aws_upload {
    declare -r EXPECTED_SIZE="$2"
    declare -r FILENAME="$1"

    # mimic bucket setup from Spilo
    # to keep logical backups at the same path as WAL
    # NB: $LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX already contains the leading "/" when set by the Postgres Operator
    PATH_TO_BACKUP=s3://$LOGICAL_BACKUP_S3_BUCKET"/spilo/"$SCOPE$LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX"/logical_backups/"$FILENAME

    args=()

    [[ ! -z "$EXPECTED_SIZE" ]] && args+=("--expected-size=$EXPECTED_SIZE")
    [[ ! -z "$LOGICAL_BACKUP_S3_ENDPOINT" ]] && args+=("--endpoint-url=$LOGICAL_BACKUP_S3_ENDPOINT")
    [[ ! "$LOGICAL_BACKUP_S3_SSE" == "" ]] && args+=("--sse=$LOGICAL_BACKUP_S3_SSE")

    aws s3 cp - "$PATH_TO_BACKUP" "${args[@]//\'/}" --debug
}

function checkin {
  if [[ -n "$HEALTHCHECK_HOST" ]]; then
    ping_url=$(curl -f --header "X-Api-Key: ${HEALTHCHECK_APIKEY}" \
               -XPOST \
               --data "@${HEALTHCHECK_CONFIG}" \
               "https://${HEALTHCHECK_HOST}/api/v1/checks/" | jq -r .ping_url -)
    curl --retry 3 -f "$ping_url"
  fi
}

function get_pods {
    declare -r SELECTOR="$1"

    curl "${K8S_API_URL}/namespaces/${POD_NAMESPACE}/pods?$SELECTOR" \
        --cacert $CERT \
        -H "Authorization: Bearer ${TOKEN}" | jq .items[].status.podIP -r
}

function get_current_pod {
    curl "${K8S_API_URL}/namespaces/${POD_NAMESPACE}/pods?fieldSelector=metadata.name%3D${HOSTNAME}" \
        --cacert $CERT \
        -H "Authorization: Bearer ${TOKEN}"
}

declare -a search_strategy=(
    list_all_replica_pods_current_node
    list_all_replica_pods_any_node
    get_master_pod
)

function list_all_replica_pods_current_node {
    get_pods "labelSelector=${CLUSTER_NAME_LABEL}%3D${SCOPE},spilo-role%3Dreplica&fieldSelector=spec.nodeName%3D${CURRENT_NODENAME}" | head -n 1
}

function list_all_replica_pods_any_node {
    get_pods "labelSelector=${CLUSTER_NAME_LABEL}%3D${SCOPE},spilo-role%3Dreplica" | head -n 1
}

function get_master_pod {
    get_pods "labelSelector=${CLUSTER_NAME_LABEL}%3D${SCOPE},spilo-role%3Dmaster" | head -n 1
}

CURRENT_NODENAME=$(get_current_pod | jq .items[].spec.nodeName --raw-output)
export CURRENT_NODENAME

for search in "${search_strategy[@]}"; do

    PGHOST=$(eval "$search")
    export PGHOST

    if [ -n "$PGHOST" ]; then
        break
    fi

done

declare -r DATE=$(date +%s)

if [[ $VERSION == "2" ]]; then
	dumpglobals | compress | encrypt | aws_upload "$DATE.globals.sql.gz" ""
	list_databases | while read -r db; do
		dumpdb "$db" | encrypt | aws_upload "$DATE.$db.dump" ""
	done
else
	dump | compress | aws_upload "$DATE.sql.gz" $(($(estimate_size) / DUMP_SIZE_COEFF))
fi
checkin
