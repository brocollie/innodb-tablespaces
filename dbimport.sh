#!/bin/bash

# Скрипт для импортирования ранее собранных tablespace.
# Удаляет все таблицы из базы данных dev;
# Запускает команды из файлов dump_1 / dump_2 (для создания новых пустых таблиц);
# Копирует tablespace'ы из папки files в папку dev_data;
# После чего производит импортирование скопированных tablespace.


dev="dev_db"
dev_data="/var/sdc2/db/mysql/${dev}"
dump_1="./dump_1.sql"
dump_2="./dump_2.sql"
files="./files"


# requires coproc, stdbuf, mysql
#args: handle query
function mysql_check {
  local handle
  handle=(${1//_/ })
  #has right structure && is still running && we opened it?
  if [[ ${#handle[*]} == 3 ]] && ps -p ${handle[2]} 2>> /dev/null >> /dev/null && { echo "" >&${handle[1]}; } 2> /dev/null; then
    return 0
  fi
  return 1
}

# open mysql connection
#args: -u user [-H host] [-p passwd] -d db
#returns $HANDLE
function mysql_connect {
  local argv argc user pass host db HANDLEID i
  #prepare args
  argv=($*)
  argc=${#argv[*]}

  #init connection and channels
  #we do it in XML cause otherwise we can't detect the end of data and so would need a read timeout O_o
  HANDLEID="MYSQL$RANDOM"
  eval "coproc $HANDLEID { stdbuf -oL mysql -s -N --force --unbuffered --xml -vvv 2>&1; }" 2> /dev/null
  HANDLE=$(eval 'echo ${'${HANDLEID}'[0]}_${'${HANDLEID}'[1]}_${'${HANDLEID}'_PID}')
  if mysql_check $HANDLE; then
    export HANDLE
    return 0
  else
    echo "ERROR: Connection failed to $user@$host->DB:$db!"
    return 1
  fi
}

#args: handle query
#return: $DATA[0] = affected rows/number of sets; 
#        $DATA[1] = key=>values pairs following
#        $DATA[2]key; DATA[3]=val ...
function mysql_query {
  local handle query affected line results_open row_open cols key val 
  if ! mysql_check $1; then
    echo "ERROR: Connection not open!"
    return 1
  fi
  handle=(${1//_/ })

  #delimit query; otherwise we block forever/timeout
  query=$2
  if [[ ! "$query" =~ \;\$ ]]; then
    query="$query;"
  fi
  #send query
  echo "$query" >&${handle[1]}

  #get output
  DATA=();
  DATA[0]=0
  DATA[1]=0
  results_open=0
  row_open=0
  cols=0
  while read -t $MYSQL_READ_TIMEOUT -ru ${handle[0]} line
  do 
    #WAS ERROR?
    if [[ "$line" == *"ERROR"* ]]; then
      echo "$line"
      return 1
    #WAS INSERT/UPDATE?
    elif [[ "$line" == *"Query OK"* ]]; then
      affected=$([[ "$line" =~ Query\ OK\,\ ([0-9]+)\ rows?\ affected ]] && echo ${BASH_REMATCH[1]})
      DATA[0]=$affected
      export DATA
      return 0
    fi

    #BEGIN OF RESULTS
    if [[ $line =~ \<resultset ]]; then
      results_open=1
    fi

    #RESULTS
    if [[ $results_open == 1 ]]; then
      if [[ $line =~ \<row ]]; then
    row_open=1
    cols=0
      elif [[ $line =~ \<field && $row_open == 1 ]]; then
    key=$([[ "$line" =~ name\=\"([^\"]+)\" ]] && echo ${BASH_REMATCH[1]})
    val=$([[ "$line" =~ \>(.*)\<\/ ]] && echo ${BASH_REMATCH[1]} || echo "NULL")
    DATA[${#DATA[*]}]=$key
    DATA[${#DATA[*]}]=$val
    cols=$[$cols+1]
      elif [[ $line =~ \<\/row ]]; then
    row_open=0
    DATA[0]=$[${DATA[0]}+1]
    DATA[1]=$cols
      fi
    fi

    #END OF RESULTS
    if [[ $line =~ \<\/resultset ]]; then
      export DATA
      return 0
    fi
  done
  #we can only get here
  #if read times out O_o
  echo "$FUNCNAME: Read timed out!"
  return 1
}

#args: handle
function mysql_close {
  local handle
  if ! mysql_check $1; then
    echo "ERROR: Connection not open!"
    return 1
  fi
  handle=(${1//_/ })
  echo "exit;" >&${handle[1]}

  if ! mysql_check $1; then
    return 0
  else
    echo "ERROR: Couldn't close connection!"
    return 1
  fi
}
############### END BASIC MYSQL SESSION IMPLEMENTATION FOR BASH ################################



export MYSQL_READ_TIMEOUT=600
mysql_connect

mysql_query $HANDLE "SET foreign_key_checks = 0"



# drop views from dev
mysql_query $HANDLE "SELECT table_schema, table_name FROM information_schema.tables WHERE table_type='VIEW' AND table_schema='${dev}'"; TABLES=("${DATA[@]}");
fields=2; for ((i=2; $i<$((${TABLES[0]}*${TABLES[1]}*$fields)); i+=$((${TABLES[1]}*$fields)))); do
    table=${TABLES[$i+3]}
    echo "DROP VIEW ${table}"
    mysql_query $HANDLE "DROP VIEW IF EXISTS \`${dev}\`.\`${table}\`"
done

# drop tables from dev
mysql_query $HANDLE "SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema='${dev}'"; TABLES=("${DATA[@]}");
fields=2; for ((i=2; $i<$((${TABLES[0]}*${TABLES[1]}*$fields)); i+=$((${TABLES[1]}*$fields)))); do
    table=${TABLES[$i+3]}
    echo "DROP ${table}"
    mysql_query $HANDLE "DROP TABLE IF EXISTS \`${dev}\`.\`${table}\`"
done


echo "IMPORT DUMP 1"
mysql ${dev} < ${dump_1}
echo "IMPORT DUMP 2"
mysql ${dev} < ${dump_2}


# discard dev tablespaces
mysql_query $HANDLE "SELECT table_schema, table_name FROM information_schema.tables WHERE engine='InnoDB' AND table_schema='${dev}'"; TABLES=("${DATA[@]}");
fields=2; for ((i=2; $i<$((${TABLES[0]}*${TABLES[1]}*$fields)); i+=$((${TABLES[1]}*$fields)))); do
    table=${TABLES[$i+3]}
    echo "DISCARD ${table}"
    mysql_query $HANDLE "ALTER TABLE \`${dev}\`.\`${table}\` DISCARD TABLESPACE"
done


echo "COPY DB FILES"
for f in ${files}/* ; do 
    echo "COPY ${f}";
    cp "$f" $(echo "${f}" | sed "s|^.*/\(.*\?\..*\)|${dev_data}/\1|g")
done
# cp -a  ${dev_data}

chown mysql ${dev_data}/*;
chgrp mysql ${dev_data}/*;
chmod 0660 ${dev_data}/*

# copying prod tablespaces to dev
mysql_query $HANDLE "SELECT table_schema, table_name FROM information_schema.tables WHERE engine='InnoDB' AND table_schema='${dev}'"; TABLES=("${DATA[@]}");
fields=2; for ((i=2; $i<$((${TABLES[0]}*${TABLES[1]}*$fields)); i+=$((${TABLES[1]}*$fields)))); do
    table=${TABLES[$i+3]}

    echo "IMPORT ${table}"
    mysql_query $HANDLE "ALTER TABLE \`${dev}\`.\`${table}\` IMPORT TABLESPACE"
    sleep 0.1s
done

