# マネジメントコンソールでIAMユーザーのアクセスキーIDとシークレットアクセスキーを作成

# 以下、ローカルマシンで操作
# ローカルマシンの環境変数にアクセスキーID等をセット
export AWS_ACCESS_KEY_ID=xxxx
export AWS_SECRET_ACCESS_KEY=xxxx
export AWS_DEFAULT_REGION=ap-northeast-1
export AWS_DEFAULT_OUTPUT=json

# EC2用、AdministratorAccessをつけたロールを準備。
aws iam create-role --role-name ec2_admin_role --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"","Effect":"Allow","Principal":{"Service":["ec2.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name ec2_admin_role --policy-arn 'arn:aws:iam::aws:policy/AdministratorAccess'

# インスタンスプロファイルを作成し、インスタンスプロファイルにロールを追加
aws iam create-instance-profile --instance-profile-name ec2_admin_role
aws iam add-role-to-instance-profile --instance-profile-name ec2_admin_role --role-name ec2_admin_role

# キーペアを生成。秘密鍵をmykey.pemとして保存。
aws ec2 create-key-pair --key-name mykey --query 'KeyMaterial' --output text > mykey.pem
chmod 400 mykey.pem

# EC2インスタンスを起動。ポート22と8888を解放。ロール(インスタンスプロファイル)を付与。
instance_id=$(aws ec2 run-instances --image-id ami-0f9ae750e8274075b --instance-type t2.micro --iam-instance-profile 'Name=ec2_admin_role' --key-name mykey --query 'Instances[].InstanceId' --output text)
echo $instance_id

# このEC2が使用しているセキュリティグループのIDを取得
ec2_security_group_id=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[].Instances[].NetworkInterfaces[].Groups[].GroupId' --output text)

# このEC2が使用しているセキュリティグループにてポート22と8888のアクセスを許可
aws ec2 authorize-security-group-ingress --group-id $ec2_security_group_id --cidr '0.0.0.0/0' --protocol 'tcp' --port '22'
aws ec2 authorize-security-group-ingress --group-id $ec2_security_group_id --cidr '0.0.0.0/0' --protocol 'tcp' --port '8888'

# EC2インスタンスのパブリックIPを表示
public_ip=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[].Instances[].PublicIpAddress' --output text)
echo $public_ip

# 以下、立ち上げたEC2インスタンスにSSH接続して操作する。
ssh -i mykey.pem ec2-user@$public_ip

# Dockerをインストール
sudo yum -y update
sudo yum -y install docker
sudo systemctl enable --now docker.service

# docker-composeをインストール
sudo curl -L https://github.com/docker/compose/releases/download/1.24.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# ec2-userがDockerを使えるようにする
sudo groupadd docker
sudo usermod -g docker ec2-user

# aws configureで、リージョン、出力形式のみ指定。
aws configure set default.region ap-northeast-1
aws configure set default.output json

# Jupyter Labを起動 (実行後, EC2のPublic IPアドレス:8888に接続。Ctrl-Cで終了)
docker run -p 8888:8888 -e JUPYTER_ENABLE_LAB=yes jupyter/minimal-notebook start.sh jupyter lab --LabApp.token=''

# Dockerfileを作成
cat << EOF > Dockerfile
FROM jupyter/minimal-notebook
ENV JUPYTER_ENABLE_LAB yes
EXPOSE 8888
RUN pip install awscli
CMD ["start.sh", "jupyter", "lab", "--LabApp.token=''"]
EOF

# Dockerfileからコンテナのイメージを作る
docker build -t myjupyter .

# イメージをコンテナとして実行 (実行後, EC2のPublic IPアドレス:8888に接続。Ctrl-Cで終了)
docker run -p 8888:8888 myjupyter

# docker-compose.ymlを作成
cat << EOF > docker-compose.yml
jupyter:
  image: myjupyter
  ports:
    - 8888:8888
EOF

# docker composeをインストール
sudo yum install -y python3
sudo pip3 install docker-compose

# docker-compose.ymlからコンテナを起動する (実行後, EC2のPublic IPアドレス:8888に接続。Ctrl-Cで終了)
docker-compose up

# ECRリポジトリを作成する
repository_uri=$(aws ecr create-repository --repository-name myrepo --query 'repository.repositoryUri' --output text)
echo $repository_uri

# myjupyterにリポジトリのURIタグをつける
docker tag myjupyter $repository_uri

# ECRにログイン
$(aws ecr get-login --no-include-email)

# ECRリポジトリにイメージをプッシュ
docker push $repository_uri

# VPCを作成
vpc_id=$(aws ec2 create-vpc --cidr-block '10.0.0.0/16' --query 'Vpc.VpcId' --output text)
echo $vpc_id

# IGWを作成
internet_gateway_id=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
echo $internet_gateway_id

# VPCにIGWをアタッチ
aws ec2 attach-internet-gateway --vpc-id $vpc_id --internet-gateway-id $internet_gateway_id

# サブネットを作成
subnet_id=$(aws ec2 create-subnet --cidr-block '10.0.0.0/24' --vpc-id $vpc_id --query 'Subnet.SubnetId' --output text)
echo $subnet_id

# ルートテーブルを作成
route_table_id=$(aws ec2 create-route-table --vpc-id $vpc_id --query 'RouteTable.RouteTableId' --output text)
echo $route_table_id

# サブネットにルートテーブルを関連付け
aws ec2 associate-route-table --route-table $route_table_id --subnet-id $subnet_id

# デフォルトルート(TO IGW)を作成
aws ec2 create-route --route-table-id $route_table_id --destination-cidr-block '0.0.0.0/0'  --gateway-id $internet_gateway_id

# セキュリティグループを作成
security_group_id=$(aws ec2 create-security-group --vpc-id $vpc_id --description 'websg' --group-name 'websg' --query 'GroupId' --output text)
echo $security_group_id

# セキュリティグループにてポート8888のアクセスを許可
aws ec2 authorize-security-group-ingress --group-id $security_group_id --cidr '0.0.0.0/0' --protocol 'tcp' --port '8888'

# ECSクラスターを作成
aws ecs create-cluster --cluster-name 'mycluster'

# IAMロール（タスクロール）を作成
aws iam create-role --role-name "ecs_task_role" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"","Effect":"Allow","Principal":{"Service":["ecs-tasks.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name "ecs_task_role" --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
ecs_task_role_arn=$(aws iam list-roles --query 'Roles[?RoleName==`ecs_task_role`].Arn' --output text)
echo $ecs_task_role_arn

# IAMロール（タスク実行ロール）を作成
aws iam create-role --role-name "ecs_exec_role" --assume-role-policy-document '{"Version":"2008-10-17","Statement":[{"Sid":"","Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name "ecs_exec_role" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
ecs_exec_role_arn=$(aws iam list-roles --query 'Roles[?RoleName==`ecs_exec_role`].Arn' --output text)
echo $ecs_exec_role_arn

# タスク定義ファイルを作成
cat << EOF > task_def.json
[
    {
        "name": "mycontainer",
        "image": "$repository_uri",
        "essential":true,
        "cpu": 1024,
        "memory": 2048,
        "portMappings":[
            {
                "protocol":"tcp",
                "hostPort": 8888,
                "containerPort":8888
            }
        ]
    }
]
EOF

# タスク定義を作成
aws ecs register-task-definition \
--requires-compatibilities '["FARGATE"]' \
--container-definitions file://task_def.json \
--network-mode "awsvpc" \
--cpu 1024 \
--memory 2048 \
--task-role-arn "$ecs_task_role_arn" \
--execution-role-arn "$ecs_exec_role_arn" \
--family "mytaskdef"

# ネットワーク設定の文字列を組み立て
cat << EOF > net_conf.json
{
    "awsvpcConfiguration":
    {
        "subnets": ["${subnet_id}"],
        "securityGroups":["${security_group_id}"],
        "assignPublicIp":"ENABLED"
    }
}
EOF

# サービスを作成
aws ecs create-service \
--cluster "mycluster" \
--service-name "myservice" \
--task-definition "mytaskdef" \
--desired-count 1 \
--launch-type "FARGATE" \
--platform-version "LATEST" \
--network-configuration file://net_conf.json

# 備考:
# この手順ではawsコマンドだけを使用して進めたが、
# より便利なECS CLIを使用することもできる。
# https://docs.aws.amazon.com/ja_jp/AmazonECS/latest/developerguide/ECS_CLI.html
