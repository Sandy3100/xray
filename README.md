## 使用
> 服务器vpn，使用xary+reality+vless的方式构建VPN，私钥和公钥是一次性生成,不需要更改，在脚本中可找到对应的privatekey，publickey。私钥在服务端配置文件中使用（/usr/local/etc/xray/config.conf），公钥在生成的客户端配置文件中
> 公私钥必须成对匹配，若要重新生成公私钥，使用xray x25519产生，并对应修改脚本，然后systemctl restart xray，重启服务
> 执行./xray_add client_name 会生成对应的json文件，二维码，url。客户端可选择相应的方式添加配置
