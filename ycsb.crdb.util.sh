# setup the schema
# confirm data is loaded based on ranges
# select substring(ycsb_key,1,6),count(*) from usertable group by 1 order by 1; 
# show testing_ranges from table usertable;

ycsb_usage() {
  cat <<EOF
  Download YCSB distro:
    curl -O --location https://raw.githubusercontent.com/robert-s-lee/distro/master/jdbc-binding-0.16.0-SNAPSHOT.tar.gz 
    if ~/ycsb-jdbc-binding-0.16.0-SNAPSHOT is present, then batching and rewritebatch will be used.
    if ~/ycsb-0.14.0 is present, then batching and rewrite batch will not be used.

  Prep, run the following in order:
    run ycsb_config to install Postgres JDBC driver in $YCSB/lib 
    run crdbnodes to tell list of of CRDB nodes to target for the run by creating $CRDB_NODES
    run ycsb_schema to setup the YCSB scehma
    run ycsb_truncate IF $insertcount needs to be modified  
 
  In local mode, each node will operate on its own range of data following the
    https://github.com/brianfrankcooper/YCSB/wiki/Running-a-Workload-in-Parallel
  In 

  Run on a current node: 
    ycsb_local 
      will insert $insertcount rows in the order of $insertorder if not alread loaded
      then run workload $workloads for $operationcount using the $requestdistribution conflict 

  Run on a specifc node:
    ycsb_local -n mbg.local:26259 
      will target mbg.local:26259

  Run on all nodes sequentally:
    ycsb_local -n "."
      will run on nodes sequetanlly as defined by $CRDB_NODES 

  Run on nodes in parallel:
    ycsb_global
EOF
}

# find out YCSB install
if [ -z "$YCSB" ]; then
  if [ -d ~/ycsb-jdbc-binding-0.16.0-SNAPSHOT ]; then
    export YCSB=~/ycsb-jdbc-binding-0.16.0-SNAPSHOT
  elif [ -d ~/ycsb-0.14.0 ]; then
    export YCSB=~/ycsb-0.14.0
  else
    echo "Cannot find YCSB install"
    return 1
  fi  
fi

export YCSB_VERSION=`basename $YCSB | awk -F'-' '{print $(NF-1)}'`

## variations on the tests
export verbose="-s"           # display stat every second
export batchsize=1000         # batchsize 
export operationcount=5000    # stop after this many operations 
export threadperinstance=2    # thread per YCSB client
export insertstart=0          # key start from user0
export insertcount=100000     # each YCSB client inserts this many keys. (1 followed by 0s.  otherwise skew)
export requestdistribution="uniform"  # uniform zipfian
#requestdistribution="zipfian"
export insertorder="ordered"  # ordered hashed.  
export workloads="a"

export CRDB_NODES=/tmp/crdbnodes.tsv

# roundrobin list of hosts:port and return host port
# rr 0 "$HOSTS"
crdbnodes () {
  cockroach node status --insecure --format tsv | tail -n +2 > $CRDB_NODES
}

# create/overview a default YCSB config
ycsb_config() {
  if [ ! -f "$YCSB/lib/postgresql-42.2.4.jar" ]; then
    curl --location https://jdbc.postgresql.org/download/postgresql-42.2.4.jar -o $YCSB/lib/postgresql-42.2.4.jar
  fi

  if [ ! -d "$YCSB/cockroachdb" ]; then
    mkdir $YCSB/cockroachdb
  fi

  if [ ! -f $YCSB/cockroachdb/db.properties ]; then
    cat >$YCSB/cockroachdb/db.properties<<EOF
    db.driver=org.postgresql.Driver
    db.url=jdbc:postgresql://127.0.0.1:26257/ycsb
    db.user=root
    db.passwd=
EOF
  fi
}

# create schema
# use the first node from $CRDB_NODES to create the schema
ycsb_schema() {
  local id host port url
  if [ ! -f "$CRDB_NODES" ]; then 
    echo "CRDB_NODES shoudl have an output of cockroach node status --format tsv"
    return 1
  fi

  cat $CRDB_NODES | tail -n 1 | awk '{split($2,a,":"); print $1 " " a[1] " " a[2]}' | while read id host port; do
    echo "id=$id host=$host port=$port" 
    url="postgresql://root@$host:$port/ycsb"

    cockroach sql --insecure --url $url <<EOF
      create database if not exists ycsb;
      use ycsb;
      CREATE TABLE if not exists usertable(YCSB_KEY VARCHAR PRIMARY KEY,
        FIELD0 VARCHAR, FIELD1 VARCHAR,
        FIELD2 VARCHAR, FIELD3 VARCHAR,
        FIELD4 VARCHAR, FIELD5 VARCHAR,
        FIELD6 VARCHAR, FIELD7 VARCHAR,
        FIELD8 VARCHAR, FIELD9 VARCHAR);
      alter table usertable split at select left(concat('user', '0', generate_series(0,9)::string),6);
      alter table usertable split at select left(concat('user', generate_series(10,99)::string),6);
      alter table usertable scatter;
EOF
  done
}

# truncate and split ranges
# each truncate hurt performance for now. shutdown, wipe out database, restart for now
ycsb_truncate() {
  local id host port url
  if [ ! -f "$CRDB_NODES" ]; then 
    echo "CRDB_NODES shoudl have an output of cockroach node status --format tsv"
    return 1
  fi

  cat $CRDB_NODES | tail -n 1 | awk '{split($2,a,":"); print $1 " " a[1] " " a[2]}' | while read id host port; do
    echo "id=$id host=$host port=$port" 
    url="postgresql://root@$host:$port/ycsb"

    cockroach sql --insecure --url $url <<EOF
      truncate ycsb.usertable;
      alter table usertable split at select left(concat('user', '0', generate_series(0,9)::string),6);
      alter table usertable split at select left(concat('user', generate_series(10,99)::string),6);
EOF
  done
}
#  
# -h hostname:port to use for loading.  Default is $(hostname):26257
# -b batchsize
# -r rewrite batch to multi-row
# -t timestame for the log Default is date +%y%m%d-%H%M
# run recordcount per shard (must start with 1)
# load recordcount operationscount
ycsb_local() {
  local nodeid host port jdbcopt
  local n insertlen
  local i
  local ts
  local bs dburl
  local batch
  local OPTIND opt
  bs=0
  ts=`date "+%y%m%d-%H%M"`

  if [ "$YCSB_VERSION" == "0.16.0" ]; then
    echo "$YCSB_VERSION automatically enabling batching and multi-row insert rewrite"
    batch="-p jdbc.batchupdateapi=true -p db.batchsize=${batchsize}"
    jdbcopt="reWriteBatchedInserts=true"
  fi
    
  while getopts "b:n:rt:" opt; do
    case "${opt}" in
      b)
        bs=${OPTARG}
        batch="-p jdbc.batchupdateapi=true -p db.batchsize=$bs"
        ;;
      r)
        jdbcopt="reWriteBatchedInserts=true"
        ;;
      n)
        nodeid=${OPTARG}
        ;;        
      t)
        ts=${OPTARG}
        ;;
      esac
  done
  shift $((OPTIND-1))

  echo "jdbcopt=$jdbcopt nodeid=$nodeid"
  if [ -z "$nodeid" ]; then
    nodeid=$(hostname):26257
  fi

  w=${workloads:-a}
  r=${requestdistribution:-uniform}
  o=${insertorder:-ordered}

  # CRDB node id, host, port 
  cat $CRDB_NODES | grep -E "$nodeid" | awk '{split($2,a,":"); print $1 " " a[1] " " a[2]}' | while read id host port; do
    echo "id=$id host=$host port=$port" 

    # id generats unqiue ranges so that other nodes don't conflict
    insertlen=$insertcount
    ((n = ($id) * $insertcount))
    echo $n

    echo load workload=$w request=$r order=$o instance=$id rec=$n

    if [ -z "${jdbcopt}" ]; then
      dburl="jdbc:postgresql://${host}:${port}/ycsb?ApplicationName=ycsb"
    else
      dburl="jdbc:postgresql://${host}:${port}/ycsb?ApplicationName=ycsb&${jdbcopt}"
    fi    

    echo "***** user${n} exists?"
    $YCSB/bin/ycsb shell jdbc  -P $YCSB/workloads/workload${w} -p db.user=root -p db.url=${dburl} -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0  -p operationcount=${operationcount}  $batch > /tmp/readkey.txt.$$ <<EOF
read user${n}
quit
EOF

    if [ "`grep 'Return code: OK' /tmp/readkey.txt.$$`" ]; then
      echo "user${n} found"
    else
      echo "***** user${n} not found.  Loading dataset before running"
      ops=load
      $YCSB/bin/ycsb ${ops} jdbc $verbose -P $YCSB/workloads/workload${w} -threads ${threadperinstance} -p db.user=root -p db.url=${dburl} -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0  -p operationcount=${operationcount}  $batch > ${ts}_ycsb_${ops}_${host}:${port}_${w}_${r}_${o}_${id}_${threadperinstance}_${n}_${bs}.log 
    fi

    rm /tmp/readkey.txt.$$

    echo "***** user${n} testing beginning"
    ops=run
    $YCSB/bin/ycsb ${ops} jdbc $verbose -P $YCSB/workloads/workload${w} -threads ${threadperinstance} -p db.user=root -p db.url=${dburl} -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0  -p operationcount=${operationcount} -p requestdistribution=${r} $batch  > ${ts}_ycsb_${ops}_${host}:${port}_${w}_${r}_${o}_${id}_${threadperinstance}_${n}_${bs}.log 

  done
}

function join_by { local IFS="$1"; shift; echo "$*"; }

ycsb_global() {
  local nodeid host port jdbcopt
  local n insertlen
  local i
  local ts
  local bs dburl dburl_delim
  local batch
  local OPTIND opt
  bs=0
  ts=`date "+%y%m%d-%H%M"`

  if [ "$YCSB_VERSION" == "0.16.0" ]; then
    echo "$YCSB_VERSION automatically enabling batching and multi-row insert rewrite"
    batch="-p jdbc.batchupdateapi=true -p db.batchsize=${batchsize}"
    jdbcopt="reWriteBatchedInserts=true"
  fi
    
  while getopts "b:n:rt:" opt; do
    case "${opt}" in
      b)
        bs=${OPTARG}
        batch="-p jdbc.batchupdateapi=true -p db.batchsize=$bs"
        ;;
      r)
        jdbcopt="reWriteBatchedInserts=true"
        ;;
      n)
        nodeid=${OPTARG}
        ;;        
      t)
        ts=${OPTARG}
        ;;
      esac
  done
  shift $((OPTIND-1))

  echo "jdbcopt=$jdbcopt nodeid=$nodeid"
  if [ -z "$nodeid" ]; then
    nodeid=$(hostname):26257
  fi

  w=${workloads:-a}
  r=${requestdistribution:-uniform}
  o=${insertorder:-ordered}
  echo load workload=$w request=$r order=$o instance=$id rec=$n

  # CRDB node id, host, port 
  cat $CRDB_NODES | awk '{split($2,a,":"); print $1 " " a[1] " " a[2]}' | while read id host port; do
    echo "id=$id host=$host port=$port" 

    # id generats unqiue ranges so that other nodes don't conflict
    insertlen=$insertcount
    ((n = ($id) * $insertcount))
    echo $n

    echo load workload=$w request=$r order=$o instance=$id rec=$n

    if [ -z "${jdbcopt}" ]; then
      dburl="jdbc:postgresql://${host}:${port}/ycsb?ApplicationName=ycsb"
    else
      dburl="jdbc:postgresql://${host}:${port}/ycsb?ApplicationName=ycsb&${jdbcopt}"
    fi    

    echo "***** user${n} exists?"
    $YCSB/bin/ycsb shell jdbc  -P $YCSB/workloads/workload${w} -p db.user=root -p db.url=${dburl} -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0  -p operationcount=${operationcount}  $batch > /tmp/readkey.txt.$$ <<EOF
read user${n}
quit
EOF

    if [ "`grep 'Return code: OK' /tmp/readkey.txt.$$`" ]; then
      echo "user${n} found"
    else
      echo "***** user${n} not found.  Loading dataset before running"
      ops=load
      $YCSB/bin/ycsb ${ops} jdbc $verbose -P $YCSB/workloads/workload${w} -threads ${threadperinstance} -p db.user=root -p db.url=${dburl} -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0  -p operationcount=${operationcount}  $batch > ${ts}_ycsb_${ops}_${host}:${port}_${w}_${r}_${o}_${id}_${threadperinstance}_${n}_${bs}.log 
    fi

    rm /tmp/readkey.txt.$$

  done

  # CRDB node id, host, port 
  if [ -z "${jdbcopt}" ]; then
    dburl=`cat $CRDB_NODES | awk '{split($2,a,":"); print "jdbc:postgresql://" a[1] ":" a[2] "/ycsb?ApplicationName=ycsb";}'`
  else
     dburl=`cat $CRDB_NODES | awk '{split($2,a,":"); print "jdbc:postgresql://" a[1] ":" a[2] "/ycsb?ApplicationName=ycsb&" jdbcopt;}' jdbcopt="${jdbcopt}"`
  fi
  dburl=`join_by "," ${dburl}`

  n=`wc -l $CRDB_NODES | awk '{print $1}'`
  ((insertlen = ($n) * $insertcount))
  n=$insertcount

    echo "***** user${n} testing beginning"
    ops=run
    $YCSB/bin/ycsb ${ops} jdbc $verbose -P $YCSB/workloads/workload${w} -threads ${threadperinstance} -p db.user=root -p db.url=${dburl}  -p insertstart=${n} -p insertcount=${insertlen} -p insertorder=${o} -p recordcount=0 -p operationcount=${operationcount} -p requestdistribution=${r} $batch  > ${ts}_ycsb_${ops}_${host}:${port}_${w}_${r}_${o}_${id}_${threadperinstance}_${n}_${bs}.log 

}

