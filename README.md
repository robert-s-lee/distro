Utility script to test YCSB easily

1. Source the script

  `. ~/ycsb.crdb.util.sh`

  A log of the run will be created after each run.  The format is

  ${ts}_ycsb_${ops}_${host}:${port}_${w}_${r}_${o}_${id}_${threadperinstance}_${n}_${bs}.log 

  - ts=%y%m%d-%H%M format
  - ops=run or load
  - host=hostname of db connection
  - port=port of db connection
  - w=YCBS worload.  Default is to use a.
  - r=workload distribution (uniform or zipifian).  Default is to use zipifian
  - o=insert order (ordered or hashed).  Default is to use ordered
  - threadperinstance=number of threads per database node
  - n=start of the YCSB_KEY
  - bs=batch size


1. Download YCSB distro:

    `curl -O --location https://raw.githubusercontent.com/robert-s-lee/distro/master/jdbc-binding-0.16.0-SNAPSHOT.tar.gz` 

    if ~/ycsb-jdbc-binding-0.16.0-SNAPSHOT is present, then batching and rewritebatch will be used.

    if ~/ycsb-0.14.0 is present, then batching and rewrite batch will not be used.

2.  Prep, run the following in order:

    - run `ycsb_config` to install Postgres JDBC driver in $YCSB/lib 
    - run `crdbnodes` to tell list of of CRDB nodes to target for the run by creating $CRDB_NODES
    - run `ycsb_schema` to setup the YCSB scehma
    - run `ycsb_truncate` IF $insertcount needs to be modified  

3. Run in eiher local or global mode
 
  - In local mode, each node will operate on its own range of data following the
    https://github.com/brianfrankcooper/YCSB/wiki/Running-a-Workload-in-Parallel
  - In global mode, one YCSB client will connect to all database nodes


4. Run in local mode
  - target database on the current node

    `ycsb_local` 
      will insert $insertcount rows in the order of $insertorder if not alread loaded
      then run workload $workloads for $operationcount using the $requestdistribution conflict 

  - Run on another node

    `ycsb_local -n mbg.local:26259` 
      will target mbg.local:26259

  - Run on all nodes sequentally:

    `ycsb_local -n "."`
      will run on nodes sequetanlly as defined by $CRDB_NODES 

5.  Run on nodes in parallel:

    `ycsb_global`
