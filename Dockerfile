# ============================================================
# Kiwi TCMS Docker 镜像配置文件
# 基于 Red Hat UBI 9 Minimal 构建
# ============================================================

# checkov:skip=CKV_DOCKER_7:确保基础镜像未使用latest版本标签。

# 基础镜像：Red Hat UBI 9 Minimal（轻量版 RHEL 9）
FROM registry.access.redhat.com/ubi9-minimal

# ============================================================
# 安装系统依赖
# ============================================================

# 启用 Nginx 1.22 模块，安装 Python 3.11、数据库驱动、SSL 证书生成工具等
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
# HTTP 端口（内部，重定向到 HTTPS）
# HTTPS 端口（实际访问端口）
EXPOSE 8080   
EXPOSE 8443   

# ============================================================
# 启动脚本
# ============================================================

# 复制启动脚本到容器内
COPY ./httpd-foreground /httpd-foreground

# 容器启动时执行启动脚本（前台运行 Nginx）
CMD /httpd-foreground

# ============================================================
# 环境变量配置
# ============================================================

ENV PATH=/venv/bin:${PATH} \      
    VIRTUAL_ENV=/venv      \      
    LC_ALL=en_US.UTF-8     \      
    LANG=en_US.UTF-8       \      
    LANGUAGE=en_US.UTF-8          

# ============================================================
# 复制 Python 虚拟环境
# ============================================================

# 复制已在 kiwitcms/buildroot 容器内构建好的虚拟环境目录
# 这有助于将开发依赖排除在此镜像之外
COPY ./dist/venv/ /venv

# ============================================================
# 复制 Kiwi TCMS 代码和配置
# ============================================================

# 复制 Django 管理脚本
COPY ./manage.py /Kiwi/

# 创建必要的目录（SSL 证书、静态文件、上传文件、定时任务）
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

# Django 命令：收集所有静态文件到 STATIC_ROOT
# --noinput：自动确认，不询问
# --link：使用符号链接而不是复制（节省空间）
RUN /Kiwi/manage.py collectstatic --noinput --link

# ============================================================
# 切换到非 root 用户（安全最佳实践）
# ============================================================

# 将文件所有权转给 UID 1001（非 root 用户）
RUN chown -R 1001 /Kiwi/ /venv/

# 切换到 UID 1001 运行容器
USER 1001