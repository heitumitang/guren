# 真人聊天模拟 —— 一键自托管
# 构建：  docker compose up -d --build
# 使用：  浏览器打开 http://<这台机器的IP>:8000/app
#
# 镜像只装「核心聊天服务」依赖（fastapi/uvicorn/pydantic），build 快、体积小、成功率高。
# 需要截图 OCR（/ocr 接口）时，进容器另装：
#   docker compose exec persona pip install -r /app/requirements-ocr.txt

FROM python:3.12-slim

# 国内源加速构建；境外用户可覆盖：docker build --build-arg PIP_INDEX=https://pypi.org/simple .
ARG PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple

WORKDIR /app

# 依赖单拎一层，代码改动不重装
COPY requirements-docker.txt .
RUN pip install --no-cache-dir -i "${PIP_INDEX}" -r requirements-docker.txt

# OCR 依赖清单也拷进镜像，留待按需安装（默认不装）
COPY requirements-ocr.txt .

COPY validator ./validator
COPY server    ./server
COPY web       ./web

# 数据（人格档案/记忆/收件箱）放卷里，容器随删随建。
# key 走浏览器填（只存浏览器）或环境变量 LLM_API_KEY（compose 的 env_file 注入），不落盘、不进镜像。
VOLUME ["/app/server/data"]

ENV LLM_BASE_URL="" LLM_MODEL=""

EXPOSE 8000
WORKDIR /app/server
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
