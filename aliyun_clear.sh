#!/bin/bash

get_Header(){
    response=$(curl -s -H "Content-Type: application/json" \
  -d '{"grant_type":"refresh_token", "refresh_token":"'$refresh_token'"}' \
  https://api.aliyundrive.com/v2/account/token)

    access_token=$(echo "$response" | sed -n 's/.*"access_token":"\([^"]*\).*/\1/p')

    drive_id=$(echo "$response" | sed -n 's/.*"default_drive_id":"\([^"]*\).*/\1/p')

    HEADER="Authorization: Bearer $access_token"
    if [ -z "$HEADER" ];then
        echo "获取access token失败" >&2
        return 1
    fi
    echo "HEADER=\"$HEADER\""
    echo "drive_id=\"$drive_id\""
    return 0
}

get_rawList(){
    _res=$(curl -s -H "$HEADER" -H "Content-Type: application/json" -X POST -d '{"drive_id": "'$drive_id'","parent_file_id": "'$file_id'"}' "https://api.aliyundrive.com/adrive/v3/file/list")
    if [ ! $? -eq 0 ] || [ -z "$(echo "$_res" | grep "items")" ];then
        echo "获取文件列表失败" >&2
        return 1
    fi
    echo "$_res"
    return 0
}

get_List(){
    _res=$raw_list
    if [ ! $? -eq 0 ];then
        return 1
    fi
    echo "$_res" | grep -o "\"file_id\":\"[^\"]*\"" | cut -d':' -f2- | tr -d '"' 
    return 0
}

get_Path(){
    _path="$(curl -s -H "$HEADER" -H "Content-Type: application/json" -X POST -d "{\"drive_id\": \"$drive_id\", \"file_id\": \"$file_id\"}" "https://api.aliyundrive.com/adrive/v1/file/get_path" | grep -o "\"name\":\"[^\"]*\"" | cut -d':' -f2- | tr -d '"' | tr '\n' '/' | awk -F'/' '{for(i=NF-1;i>0;i--){printf("/%s",$i)}; printf("%s\n",$NF)}')"
    if [ -z "$_path" ];then
        return 1
    fi
    echo "$_path"
    return 0
}

delete_File(){
    _file_id=$1
    _name="$(echo "$raw_list" | grep -o "\"name\":\"[^\"]*\"" | cut -d':' -f2- | tr -d '"' | grep -n . | grep "^$(echo "$raw_list" | grep -o "\"file_id\":\"[^\"]*\"" | cut -d':' -f2- | tr -d '"' | grep -n . | grep "$_file_id" | awk -F: '{print $1}'):" | awk -F: '{print $2}')"
  
    _res=$(curl -s -H "$HEADER" -H "Content-Type: application/json" -X POST -d '{
  "requests": [
    {
      "body": {
        "drive_id": "'$drive_id'",
        "file_id": "'$_file_id'"
      },
      "headers": {
        "Content-Type": "application/json"
      },
      "id": "'$_file_id'",
      "method": "POST",
      "url": "/file/delete"
    }
  ],
  "resource": "file"
}' "https://api.aliyundrive.com/v3/batch" | grep "\"status\":204")
    if [ -z "$_res" ];then
        return 1
    fi
    
    echo "彻底删除文件：$path/$_name"
    
    return 0
}

retry_command() {
    # 重试次数和最大重试次数
    retries=0
    max_retries=10
    local cmd="$1"
    local success=false
    local output=""

    while ! $success && [ $retries -lt $max_retries ]; do
        output=$(eval "$cmd" 2>&1)
        if [ $? -eq 0 ]; then
            success=true
        else
            retries=$(($retries+1))
            echo "Failed to execute command \"$(echo "$cmd" | awk '{print $1}')\", retrying in 1 seconds (retry $retries of $max_retries)..." >&2
            sleep 1
        fi
    done

    if $success; then
        echo "$output"
        return 0
    else
        echo "Failed to execute command after $max_retries retries: $cmd" >&2
        echo "Command output: $output" >&2
        return 1
    fi
}

# 签到是抄小雅的
get_json_value(){
    local json=$1
    local key=$2

    if [[ -z "$3" ]]; then
        local num=1
    else
        local num=$3
    fi

    local value=$(echo "${json}" | awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'${key}'\042/){print $(i+1)}}}' | tr -d    '"' | sed -n ${num}p)
    echo ${value}
}

checkin(){
    local _refresh_token=$1
    local _token=$(curl -s  -X POST -H "Content-Type: application/json" -d '{"grant_type": "refresh_token", "refresh_token":                 "'"$_refresh_token"'"}' https://auth.aliyundrive.com/v2/account/token)
local _access_token=$(get_json_value $_token "access_token")

    local _sign=$(curl -s -X POST -H "Content-Type: application/json" -H 'Authorization:Bearer '$_access_token'' -d '{"grant_type":           "refresh_token", "refresh_token": "'"$_refresh_token"'"}' https://member.aliyundrive.com/v1/activity/sign_in_list)

    local _success=$(echo $_sign|cut -f1 -d, |cut -f2 -d:)
    if [ $_success = "true" ]; then
        echo -e "\033[32m"
        echo "阿里签到成功"
        echo -e "\033[0m"
        return 0
    else
        echo -e "\033[31m"
        echo "阿里签到失败"
        echo -e "\033[0m"
        return 1
    fi
}

aliyun_update_checkin_single(){
    tokens="$(read_File $1)"
    echo "$tokens" | sed '/^$/d' | while read token; do
        retry_command "checkin $token"
        response=$(curl -s -H "Content-Type: application/json" \
        -d '{"grant_type":"refresh_token", "refresh_token":"'$token'"}' \
        https://api.aliyundrive.com/v2/account/token)
        new_refresh_token=$(echo "$response" | sed -n 's/.*"refresh_token":"\([^"]*\).*/\1/p')
        if [ -n "$new_refresh_token" ];then
            docker exec "$XIAOYA_NAME" sed -i 's/'"$token"'/'"$new_refresh_token"'/g' "/data/$1"
        fi
    done
}

aliyun_update_checkin(){
    aliyun_update_checkin_single "mycheckintoken.txt"
    aliyun_update_checkin_single "mytoken.txt"
}

_clear_aliyun(){
    eval "$(retry_command "get_Header")"
    raw_list=$(retry_command "get_rawList")
    path=$(retry_command "get_Path")
    _list="$(get_List)"
    echo "$_list" | sed '/^$/d' | while read line;do
        retry_command "delete_File \"$line\""
    done
    return "$(echo "$_list" | sed '/^$/d' | wc -l)"
}

clear_aliyun() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')]开始清理小雅$XIAOYA_NAME转存"
    
    _res=1
    _filenum=0
    while [ ! $_res -eq 0 ];do
        _clear_aliyun
        _res=$?
        _filenum=$(($_filenum+$_res))
    done
    
    echo "本次共清理小雅$XIAOYA_NAME转存文件$_filenum个"

}

init_para(){
    XIAOYA_NAME="$1"
    refresh_token="$(read_File mytoken.txt | head -n1)"

    post_cmd="$(read_File mycmd.txt)"
    if [ -z "$post_cmd" ];then
        post_cmd='docker restart "'$XIAOYA_NAME'" >/dev/null 2>&1'
    fi

    file_id=$(read_File temp_transfer_folder_id.txt)
    
    _file_time="$(read_File myruntime.txt | grep -Eo "[0-9]{2}:[0-9]{2}" | tr '\n' ' ')"
    
    run_time="$script_run_time"
    if [ -n "$_file_time" ];then
        run_time="$_file_time"
    fi

}

clear_aliyun_realtime(){
    eval "_file_count_new_$XIAOYA_NAME=$(docker logs $XIAOYA_NAME 2>&1 | grep https | wc -l)"
    eval "_file_count_new=\"\$_file_count_new_$XIAOYA_NAME\""
    eval "_file_count_old=\"\$_file_count_old_$XIAOYA_NAME\""
    if [ "$_file_count_new"x != "$_file_count_old"x ];then
        clear_aliyun
    fi
    eval "_file_count_old_$XIAOYA_NAME=\"\$_file_count_new_$XIAOYA_NAME\""
}

clear_aliyun_single_docker(){
    init_para "$1"
    case "$run_mode" in
        0)
            for time in $(echo "$run_time" | tr ',' ' '); do
                if [ "$current_time" = "$time" ]; then
                    clear_aliyun
                    aliyun_update_checkin
                    eval "$post_cmd"
                fi
            done
        ;;
        55)
            clear_aliyun_realtime
            for time in $(echo "$run_time" | tr ',' ' '); do
                if [ "$current_time" = "$time" ]; then
                    clear_aliyun
                    aliyun_update_checkin
                    eval "$post_cmd"
                fi
            done
        ;;
        1)
            clear_aliyun
            aliyun_update_checkin
        ;;
        *)
            return 1
        ;;
    esac
}

clear_aliyun_all_docker(){
    dockers="$(docker ps --filter "ancestor=xiaoyaliu/alist:latest" --format '{{.Names}}')\n$(docker ps -a --filter "ancestor=xiaoyaliu/alist:hostmode" --format '{{.Names}}')"
    current_time="$(date +%H:%M)"
    for line in $(echo -e "$dockers" | sed '/^$/d'); do
        clear_aliyun_single_docker "$line"
    done
}

gen_post_cmd_single(){
    init_para "$1"
    para_v="$(docker inspect --format='{{range $v,$conf := .Mounts}}-v {{$conf.Source}}:{{$conf.Destination}} {{$conf.Type}}~{{end}}' $XIAOYA_NAME | tr '~' '\n' | grep bind | sed 's/bind//g' | grep -Eo "\-v .*:.*" | tr '\n' ' ')"
    para_n="$(docker inspect --format='{{range $m, $conf := .NetworkSettings.Networks}}--network={{$m}}{{end}}' $XIAOYA_NAME | grep -Eo "\-\-network=host")"
    para_p="$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}} {{$p}}{{$conf}} {{end}}' $XIAOYA_NAME | tr '/' ' ' | tr -d '[]{}' | awk '{printf("-p %s:%s\n",$3,$1)}' | grep -Eo "\-p [0-9]{1,10}:[0-9]{1,10}" | tr '\n' ' ')"
    para_i="$(docker inspect --format='{{range $v, $conf := .Config}}{{if eq $v "Image"}}{{$conf}}{{end}}{{end}}' $XIAOYA_NAME)"
    cmd='
docker stop '$XIAOYA_NAME'
docker rm '$XIAOYA_NAME'
docker pull '$para_i'
docker run -d '$para_n' '$para_v' '$para_p' --restart=always --name='$XIAOYA_NAME' '$para_i'
	'
	write_File mycmd.txt "$cmd"
}

gen_post_cmd_all(){
    dockers="$(docker ps --filter "ancestor=xiaoyaliu/alist:latest" --format '{{.Names}}')\n$(docker ps -a --filter "ancestor=xiaoyaliu/alist:hostmode" --format '{{.Names}}')"
    echo -e "$dockers" | sed '/^$/d' | while read line; do
        gen_post_cmd_single "$line"
    done
}

install_keeper(){
    dockers="$(docker ps --filter "ancestor=xiaoyaliu/alist:latest" --format '{{.Names}}')\n$(docker ps -a --filter "ancestor=xiaoyaliu/alist:hostmode" --format '{{.Names}}')"
    XIAOYA_NAME="$(echo -e "$dockers" | sed '/^$/d' | head -n1)"
    XIAOYA_ROOT="$(docker inspect --format='{{range $v,$conf := .Mounts}}{{$conf.Source}}:{{$conf.Destination}}{{$conf.Type}}~{{end}}' "$XIAOYA_NAME" | tr '~' '\n' | grep bind | sed 's/bind//g' | grep ":/data" | awk -F: '{print $1}')"
    curl -s "https://xiaoyahelper.zengge99.ml/aliyun_clear.sh" -o "$XIAOYA_ROOT/aliyun_clear.sh"
    docker rm -f xiaoyakeeper >/dev/null 2>&1
    docker run --name xiaoyakeeper --restart=always --privileged -v /var/run/docker.sock:/var/run/docker.sock -v "$(which docker)":/usr/bin/docker -e TZ="Asia/Shanghai" -d nginx
    docker exec xiaoyakeeper mkdir /etc/xiaoya
    docker cp $XIAOYA_ROOT/aliyun_clear.sh xiaoyakeeper:/etc/xiaoya/aliyun_clear.sh
   docker exec xiaoyakeeper chmod +x "/etc/xiaoya/aliyun_clear.sh"
   rm -f "$XIAOYA_ROOT/aliyun_clear.sh"
    
    if ! docker exec xiaoyakeeper cat /docker-entrypoint.sh | grep aliyun_clear >/dev/null 2>&1;then
        docker cp xiaoyakeeper:/docker-entrypoint.sh $XIAOYA_ROOT/docker-entrypoint.sh
        line="$(grep "exec \"\$\@\"" -n $XIAOYA_ROOT/docker-entrypoint.sh | awk -F: '{print $1}')"
        sed -i "${line}i /etc/xiaoya/aliyun_clear.sh $1 &" $XIAOYA_ROOT/docker-entrypoint.sh
        docker cp $XIAOYA_ROOT/docker-entrypoint.sh xiaoyakeeper:/docker-entrypoint.sh
        rm -f $XIAOYA_ROOT/docker-entrypoint.sh
    fi
    docker exec xiaoyakeeper apt update >/dev/null 2>&1
    docker exec xiaoyakeeper apt install -y libltdl7 >/dev/null 2>&1
    docker exec xiaoyakeeper apt install -y libnss3 >/dev/null 2>&1
    docker restart xiaoyakeeper >/dev/null 2>&1
    
    if [ -z "$(docker ps | grep xiaoyakeeper)" ];then
        echo "启动失败，请把命令报错信息以及以下信息反馈给作者修改"
        echo "系统信息：$(uname -a)"
        echo "docker路径：$(which docker)"
        echo "docker状态：$(docker ps | grep xiaoyakeeper)"
        echo "docker运行日志："
        echo "$(docker logs --tail 10 xiaoyakeeper)"
    else
        echo "小雅看护docker(xiaoyakeeper)已启动"
    fi
}

read_File(){
    _res=""
    if docker exec "$XIAOYA_NAME" [ -f "/data/$1" ] ; then
        _res="$(docker exec "$XIAOYA_NAME" cat "/data/$1")"
    fi
    echo "$_res"
}

write_File(){
    docker exec "$XIAOYA_NAME" bash -c "echo \"$2\" > \"/data/$1\""
}

run_mode=0
next_min=$(($(date +%s) + 60))
script_run_time="$(date -d "@$next_min" +'%H:%M')"

if [ -n "$1" ];then
    run_mode="$1"
fi

dockers="$(docker ps --filter "ancestor=xiaoyaliu/alist:latest" --format '{{.Names}}')\n$(docker ps -a --filter "ancestor=xiaoyaliu/alist:hostmode" --format '{{.Names}}')"
if [ -z "$(echo -e "$dockers" | sed '/^$/d' | head -n1)" ];then
    echo "你还没有安装小雅docker，请先安装！"
    exit 0
fi

case "$run_mode" in
    0|55)
        while true; do
            clear_aliyun_all_docker
            sleep $((60 - $(date +%s) % 60))
        done
    ;;
    1)
        clear_aliyun_all_docker
    ;;
    2)
        echo "本模式已不再支持，建议使用模式3或模式4"
    ;;
    3|4)
        install_keeper 0
        gen_post_cmd_all
    ;;
    5)
        install_keeper 55
        gen_post_cmd_all
    ;;
    *)
        echo "不支持的模式"
    ;;
esac

