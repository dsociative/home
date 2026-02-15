---
title: "Artem Prikhodin"
description: "Backend Developer — Rust, Go, Python. 15+ years building high-load systems."
---

## About

Backend developer with 15+ years of experience. Five years of Python in gamedev, four years building an RTB platform in Go, then e-commerce and food delivery at scale. Now writing Rust — systems programming, high-load media processing, streaming data pipelines.

Strong DevOps background — equally comfortable designing service architecture and debugging infrastructure.

## Stack
* **Languages**: Rust, Go, Python
* **Data**: PostgreSQL (hundreds of millions of rows), Elasticsearch (billions of records), Redis, ClickHouse, Kafka, MongoDB
* **Infra**: Kubernetes, Docker, Terraform, Ansible, Prometheus, FluxCD, Nginx
* **Rust ecosystem**: Tokio, Axum, tonic (gRPC), tracing, metrics-rs, egui
* **Practices**: TDD, CI/CD, observability-first, infrastructure as code

## Experience

### Wildberries — Rust Backend Developer
*2024 — present*

One of the largest marketplaces in Russia. Started in the media rendering team — transcoding and processing product photos and videos for CDN delivery across the platform. Later moved to a new team building the user reviews pipeline: ingesting, processing and serving billions of review records with a focus on reliability and low-latency delivery under heavy traffic.

{{< techs >}}{{< tech "Rust" >}} {{< tech "Tokio" >}} {{< tech "Axum" >}} {{< tech "FFmpeg" >}} {{< tech "PostgreSQL" >}} {{< tech "Kafka" >}} {{< tech "Elasticsearch" >}} {{< tech "Kubernetes" >}} {{< tech "Ansible" >}}{{< /techs >}}

---

### Histoscan — DevOps / Go Backend Developer
*2023 — 2024*

Digital pathology platform — storing and viewing high-resolution scans from pathology scanners via a web application. Built hybrid infrastructure: cloud for the application layer, bare metal servers deployed directly in hospitals (Russian medical data regulations require data to stay on-premises). Converted scanner output to DeepZoom format for web viewing, experimented with Rust + OpenSlide (C library) for more efficient image processing. Small team, wore multiple hats — infrastructure, backend, tooling.

{{< techs >}}{{< tech "Go" >}} {{< tech "Rust" >}} {{< tech "PostgreSQL" >}} {{< tech "Kubernetes" >}} {{< tech "Helm" >}} {{< tech "FluxCD" >}} {{< tech "Terraform" >}} {{< tech "GraphQL" >}}{{< /techs >}}

---

### Yandex — Backend Developer
*2022 — 2023*

Yandex Eda. Joined briefly after Delivery Club acquisition. Short stint.

---

### Delivery Club — Go Senior Backend Developer
*2020 — 2022*

Grocery delivery division. Started in the catalog team — storing and serving the entire grocery product catalog across all partners. Later moved to the infrastructure team which handled everything that didn't fit elsewhere. Built a library that solved Kafka choking on large partner catalog syncs — abstracted S3 + Protobuf + Kafka behind a single facade so producers/consumers didn't care where data actually lived. Built an auto-generated admin panel system — codegen from Swagger specs produced Vue.js dashboards for any microservice, giving managers access to service data without engineers. Also worked on delivery time slots and was starting integration testing with Allure reporting when the company was acquired by Yandex.

{{< techs >}}{{< tech "Go" >}} {{< tech "PostgreSQL" >}} {{< tech "Kafka" >}} {{< tech "gRPC" >}} {{< tech "Swagger" >}}{{< /techs >}}

---

### Cheapshot — Go Senior Backend Developer
*2019 — 2020*

Geo-based multiplayer mobile strategy game — players see a Google Maps view of their real location, build emoji structures that farm coins, and send units to raid other players' buildings. The game had thousands of concurrent users but was running on a single Go server. My main task was horizontal scaling: I split the game world into S2 Geometry zones, each served by a dedicated server, with seamless player handoff between zones as they moved through the real world via WebSocket connections.

{{< techs >}}{{< tech "Go" >}} {{< tech "S2 Geometry" >}} {{< tech "WebSocket" >}} {{< tech "Protobuf" >}} {{< tech "PostgreSQL" >}}{{< /techs >}}

---

### BridgeLLC — Senior Backend Developer / DevOps
*2015 — 2019*

Ad-tech startup. Joined as a Python developer transitioning to Go — the team was just me, a PM, and a junior whose codebase needed a full rewrite. First project was reviving a broken bidder for Google AdX (DoubleClick, Protobuf protocol). After that, built a new OpenRTB bidder from scratch — this became the core product.

The bidder participated in real-time ad auctions with a 100ms window, handling 2–10K RPS across all servers. Infrastructure was geo-distributed across DigitalOcean datacenters in Europe and the US to minimize latency, with occasional AWS for exotic regions like Japan. Built a budget microservice so bidders in different regions spent from a shared client budget rather than isolated pools. Built an ad server that delivered creatives in multiple formats — display, video, in-app.

Analytics evolved over time: started with Apache Pig and Spark processing auction logs into MongoDB aggregates, then migrated to ClickHouse which let us query everything in real time — a massive improvement over the MapReduce approach. RabbitMQ distributed campaign configs and targeting data to bidders.

DevOps was half the job. Tooling evolved from Chef → Ansible → Terraform + Packer. Built a fully automated deployment pipeline: Packer baked VM images with Consul, Docker, and Registrator pre-installed, so a new instance would join the cluster automatically on boot — essentially a hand-rolled predecessor to Kubernetes, back when container orchestration was still maturing. Later hired and mentored junior developers as the platform grew.

{{< techs >}}{{< tech "Go" >}} {{< tech "Terraform" >}} {{< tech "Packer" >}} {{< tech "Ansible" >}} {{< tech "Consul" >}} {{< tech "Docker" >}} {{< tech "RabbitMQ" >}} {{< tech "ClickHouse" >}} {{< tech "Spark" >}} {{< tech "Redis" >}} {{< tech "DigitalOcean" >}} {{< tech "AWS" >}}{{< /techs >}}

---

### My Dragon — Python Backend Developer
*2012 — 2015*

PvP match-3 social game on VKontakte and Odnoklassniki — players raised dragons and battled other players in real-time turn-based matches on a match-3 board, where crystal combos dealt damage. Two-person team: I handled the entire backend and infrastructure, my partner did game design, PM, and the Flash client. Built a custom TCP socket server reusing libraries from my previous project. Implemented a Redis micro-ORM with a diff layer on top — the server tracked which data changed within a game command and sent only the delta to the client, giving a universal response format instead of custom payloads per command. Set up CI/CD with Buildbot, managed Linux servers. The game launched and generated revenue for both of us for several years.

{{< techs >}}{{< tech "Python" >}} {{< tech "Tornado" >}} {{< tech "Redis" >}} {{< tech "Buildbot" >}} {{< tech "Linux" >}}{{< /techs >}}

---

### ezscratch — Python Backend Developer
*2012*

Online casino project run by a distributed team. Short stint — built a server for a lottery-style casino game. The project itself wasn't a fit, but it was my first exposure to modern engineering practices: CI/CD pipelines, code reviews, dailies, retros — workflows I carried into every role after.

---

### Addicted Company — Python Backend Developer
*2011 — 2012*

Social game "Magnaty" on VKontakte/Odnoklassniki — a city-building game during the peak era of social network gaming. Built a TCP socket server handling persistent client connections (live connections instead of HTTP, unusual for the time). Wrote a micro-ORM that mapped game entities — player data, buildings, inventory — into a Redis key hierarchy. These libraries became the foundation I reused in later game projects. Team of six: PM, game designer, two Flash devs, a frontend, and a junior backend.

{{< techs >}}{{< tech "Python" >}} {{< tech "Redis" >}} {{< tech "Flash" >}}{{< /techs >}}

---

### Ravelin — Python Backend Developer
*2010 — 2011*

First production experience. Browser-based strategy game in a fantasy setting — a Travian-style game based on the "Richard the Lionheart" book series by Gai Yuliy Orlovsky. Started by building internal tooling — a Flask-based unit calculator for battle balance. Then moved to the game server itself on Tornado. Team of two (lead + me). Left before release; the game eventually launched but didn't find success.

{{< techs >}}{{< tech "Python" >}} {{< tech "Flask" >}} {{< tech "Tornado" >}} {{< tech "Redis" >}}{{< /techs >}}

## Contact
* <i class="devicon-google-plain"></i> [admin@geektech.ru](mailto:admin@geektech.ru)
* <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-2px"><path d="M11.944 0A12 12 0 000 12a12 12 0 0012 12 12 12 0 0012-12A12 12 0 0012 0h-.056zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 01.171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg> [Telegram @dsociative](https://t.me/dsociative)
* <i class="devicon-github-original"></i> [GitHub](https://github.com/dsociative)
* <i class="devicon-linkedin-plain"></i> [LinkedIn](https://www.linkedin.com/in/artem-prikhodin-ba769237)
