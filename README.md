## 使用
### 服务器配置
在服务器环境配置xray，执行一键配置脚本，会自动安装xray，配置秘钥和UUID，设置防火墙，并生成工具脚本
```
./xray_server_setup.sh
```
### 添加用户
执行生成的add-user脚本，即可添加用户到服务配置文件config.json中，并在xray-clients下产生客户端的配置json文件和url文件
```
xray-reality-add-user host_name
```
