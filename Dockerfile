#======================================================
# TCMS Docker 镜像配置文件
# 基于Red Hat UBI 9 Minimal 构建
#======================================================


# checkov:skip=CKV_DOCKER_7:确保基础镜像未使用latest版本标签

# 基础镜像：Red Hat UBI 9 Minimal（轻量版 RHEL 9）
FROM registry.access.redhat.com/ubi9-minimal

# =====================================================
# 安装系统依赖
#======================================================

# 启动 nginx 1.22模块， 安装 python 3.11 , 数据库驱动， SSL 证书生成工具等
# - microdnf：轻量级包管理器
# - -y：自动确认所有提示
# - --nodocs：不安装文档，减小镜像体积

RUN microdnf -y module enable nginx:1.22 && \
    microdnf -y --nodocs install python3.11 mariadb-connector-c libpq \
    nginx-core sscg tar glibc-langpack-en && \
    microdnf -y --nodocs update && \
    microdnf clean all


# ============================================================
# 健康检查配置
# ============================================================

# Docker 定期检查容器是否正常运行
# 访问登录页面，成功则容器健康

HEALTHCHECK CMD curl --fail -k -H "Referer: healthcheck" https://127.0.0.1:8443/accounts/login/

# ============================================================
# 端口暴露
# ============================================================
#http端口（内部，重定向到https）
#https端口（实际访问端口）

EXPOSE 8080  
EXPOSE 8443 

#=================================================================
#启动脚本
#=================================================================

#复制启动脚本到容器内
COPY ./httpd-foreground /httpd-foreground

#容器启动时执行启动脚本（前台运行Nginx）
CMD /httpd-foreground

#================================================================
#环境变量配置
#================================================================
#优先使用虚拟环境中的Python
#Python虚拟环境位置
#设置语言为英文UTB-8
ENV PATH=/venv/bin:${PATH} \                        
    VIRTUAL_ENV=/venv      \
    LC_ALL=en_US.UTF-8     \
    LANG=en_US.UTF-8       \
    LANGUAGE=en_US.UTF-8


# ============================================================
# 复制 Python 虚拟环境
# ============================================================
# copy virtualenv dir which has been built inside the kiwitcms/buildroot container
# this helps keep -devel dependencies outside of this image
COPY ./dist/venv/ /venv

#复制Django 管理脚本
COPY ./manage.py /Kiwi/

## 创建必要的目录（SSL 证书、静态文件、上传文件、定时任务）
# create directories so we can properly set ownership for them
RUN mkdir -p /Kiwi/ssl /Kiwi/static /Kiwi/uploads /Kiwi/etc/cron.jobs

# 复制配置文件
COPY ./etc/*.conf /Kiwi/etc/
COPY ./etc/cron.jobs/* /Kiwi/etc/cron.jobs/



# ============================================================
# 生成自签名 SSL 证书
# ============================================================
# 使用 sscg 工具生成自签名证书
# - 国家：BG（保加利亚）
# - 城市：Sofia（索菲亚）
# - 组织：Kiwi TCMS
# generate self-signed SSL certificate
RUN /usr/bin/sscg -v -f \
    --country BG --locality Sofia \
    --organization "Kiwi TCMS" \
    --organizational-unit "Quality Engineering" \
    --ca-file       /Kiwi/static/ca.crt     \
    --cert-file     /Kiwi/ssl/localhost.crt \
    --cert-key-file /Kiwi/ssl/localhost.key

# ============================================================
# 配置切换（开发环境 → 生产环境）
# ============================================================
# 将 Django 配置从 devel（开发）切换到 product（生产）
# 并创建 SSL 证书的软链接到系统目录
RUN sed -i "s/tcms.settings.devel/tcms.settings.product/" /Kiwi/manage.py && \
    ln -s /Kiwi/ssl/localhost.crt /etc/pki/tls/certs/localhost.crt && \
    ln -s /Kiwi/ssl/localhost.key /etc/pki/tls/private/localhost.key



# ============================================================
# 收集静态文件
# ============================================================
# collect static files
RUN /Kiwi/manage.py collectstatic --noinput --link

# ============================================================
# 切换到非 root 用户（安全最佳实践）
# ============================================================
# from now on execute as non-root
RUN chown -R 1001 /Kiwi/ /venv/
USER 1001