#!/bin/bash
dir=$(dirname ${0})
ssb_home=$dir/../ssb-benchmark

# configurations
LOCAL_TMP_DIR=/tmp
HDFS_BASE_DIR=/user/kylin_manager_user/ssb
PARALLEL_TASKS=10

KYLIN_INSTALL_USER=kylin_manager_user
KYLIN_INSTALL_USER_PASSWD=xxxxxxxx
KYLIN_INSTALL_USER_KEYTAB=/home/${KYLIN_INSTALL_USER}/keytab/${KYLIN_INSTALL_USER}.keytab

# update "hiveserve2_ip:10000" variable to actual hiveserver2 address
BEELINE_URL=jdbc:hive2://hiveserve2_ip:10000

# use beeline to access hive, user:kylin_manager_user password: xxxxxxxx
HIVE_BEELINE_COMMAND="beeline -u ${BEELINE_URL} -n ${KYLIN_INSTALL_USER} -p ${KYLIN_INSTALL_USER_PASSWD} -d org.apache.hive.jdbc.HiveDriver"

partition=false
database=ssb
scale=0.1

# before running again, delete exist tables and views
tables="customer lineorder part supplier dates"
views="p_lineorder"

while [[ $# -ge 1 ]]
do
    key="$1"
    case $key in
        --partition)
            partition=true
            echo "enable hive partition"
            ;;
        --database)
            database="$2"
            echo "database changed to ${database}"
            shift
            ;;
        --hdfs-dir)
            HDFS_BASE_DIR="$2"
            echo "hdfs base dir changed to ${HDFS_BASE_DIR}"
            shift
            ;;
        --scale)
            scale="$2"
            echo "scale changed to ${scale}"
            shift
            ;;
        --parallel)
            PARALLEL_TASKS="$2"
            echo "parallel changed to ${PARALLEL_TASKS}"
            shift
            ;;
        *)
            ;;

    esac
    shift
done

# check for existence of hadoop streaming
if [ -n "$HADOOP_HOME" ]; then
    # for hadoop 1.0.x
    if [ -z "$HADOOP_STREAMING_JAR" ] && [ -e $HADOOP_HOME/contrib/streaming/hadoop-streaming-*.jar ]; then
        HADOOP_STREAMING_JAR=$HADOOP_HOME/contrib/streaming/hadoop-streaming-*.jar
    fi
    # for hadoop 2.0.x
    if [ -z "$HADOOP_STREAMING_JAR" ] && [ -e $HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-*.jar ]; then
        HADOOP_STREAMING_JAR=$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-*.jar
    fi
    # for other hadoop version
    if [ -z "$HADOOP_STREAMING_JAR" ]; then
        HADOOP_STREAMING_JAR=`find $HADOOP_HOME -name hadoop-stream*.jar -type f`
    fi
else
    # for hadoop 1.0.x
    if [ -z "$HADOOP_STREAMING_JAR" ] && [ -e `dirname ${HADOOP_EXAMPLES_JAR}`/contrib/streaming/hadoop-streaming-*.jar ]; then
        HADOOP_STREAMING_JAR=`dirname ${HADOOP_EXAMPLES_JAR}`/contrib/streaming/hadoop-streaming-*.jar
    fi
    # for hadoop 2.0.x
    if [ -z "$HADOOP_STREAMING_JAR" ] && [ -e `dirname ${HADOOP_EXAMPLES_JAR}`/../tools/lib/hadoop-streaming-*.jar ]; then
        HADOOP_STREAMING_JAR=`dirname ${HADOOP_EXAMPLES_JAR}`/../tools/lib/hadoop-streaming-*.jar
    fi
fi

if [ -z "$HADOOP_STREAMING_JAR" ]; then
    echo 'Can not find hadoop-streaming jar file, please set HADOOP_STREAMING_JAR path.'
    exit
fi

# clean up temp files
rm -f $LOCAL_TMP_DIR/ssb/input/*
mkdir -p $LOCAL_TMP_DIR/ssb/input
for c in $(seq $PARALLEL_TASKS);do
    echo "${c}" > $LOCAL_TMP_DIR/ssb/input/$c.txt
    echo "${HDFS_BASE_DIR}" >> $LOCAL_TMP_DIR/ssb/input/$c.txt
    echo "${scale}" >> $LOCAL_TMP_DIR/ssb/input/$c.txt
    echo "${PARALLEL_TASKS}" >> $LOCAL_TMP_DIR/ssb/input/$c.txt
done

# clean up hive metadata
#hive -e "DROP DATABASE IF EXISTS ${database} CASCADE;"
# Hive+Sentry
# delete tables in database
for table in ${tables}
do
    ${HIVE_BEELINE_COMMAND} -e "DROP TABLE IF EXISTS ${database}.${table};"
done

# delete views in database
for view in ${views}
do
    ${HIVE_BEELINE_COMMAND} -e "DROP view IF EXISTS ${database}.${view};"
done


# clean up previous data if available
# kinit
kinit -kt ${KYLIN_INSTALL_USER_KEYTAB} ${KYLIN_INSTALL_USER}
hadoop fs -rm -r $HDFS_BASE_DIR
hadoop fs -mkdir -p $HDFS_BASE_DIR
hadoop fs -mkdir -p $HDFS_BASE_DIR/tmp
hadoop fs -moveFromLocal $LOCAL_TMP_DIR/ssb/input $HDFS_BASE_DIR/tmp
hadoop fs -mkdir -p $HDFS_BASE_DIR/data
for tbl in customer part supplier date lineorder
do
    hadoop fs -mkdir -p $HDFS_BASE_DIR/data/$tbl
    hadoop fs -chmod 777 $HDFS_BASE_DIR/data/$tbl
done

# run hadoop streaming job
OPTION="-D mapred.reduce.tasks=0 \
-D mapred.job.name=generate_ssb_date \
-D mapred.task.timeout=0 \
-input ${HDFS_BASE_DIR}/tmp/input \
-output ${HDFS_BASE_DIR}/data/output \
-mapper ${dir}/dbgen.sh \
-file ${dir}/dbgen.sh -file ${dir}/ssb.conf -file ${ssb_home}/dbgen -file ${ssb_home}/dists.dss"

echo hadoop jar ${HADOOP_STREAMING_JAR} ${OPTION}

hadoop jar ${HADOOP_STREAMING_JAR} ${OPTION}

echo "Creating Hive External Tables"
ls $dir/../hive/* | xargs -I {} cp {} {}.tmp
sed -i -e "s/<DATABASE>/${database}/g" $dir/../hive/*.tmp
sed -i -e "s|<hdfs-dir>|${HDFS_BASE_DIR}|g" $dir/../hive/*.tmp
${HIVE_BEELINE_COMMAND} -f $dir/../hive/1_create_basic.sql.tmp
if [ "${partition}" == "true" ]
then
    echo "Creating Hive Partitioned Table, may cost some time..."
    ${HIVE_BEELINE_COMMAND} -f $dir/../hive/2_create_partitions.sql.tmp
else
    echo "Creating Hive View"
    ${HIVE_BEELINE_COMMAND} -f $dir/../hive/2_create_views.sql.tmp
fi
rm $dir/../hive/*.tmp
