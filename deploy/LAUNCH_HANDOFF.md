# Handoff de lançamento — itens que NÃO são código

Entregáveis de código da sequência de lançamento comercial já implementados e
com a suíte verde em cada commit (`SOM-IDLE: …`, "== RESULT: N checks, 0
failures =="):

- **1a** consentimento LGPD afirmativo no cadastro (versão/ts/IP persistidos).
- **1b** exclusão/anonimização de conta (art. 18) preservando o ledger financeiro.
- **1c** webhook com assinatura de provedor (Stripe, anti-replay) + catálogo
  autoritativo de SKUs (o valor concedido nunca vem do corpo).
- **1d** reembolso CDC art. 49 (7 dias, só gems não gastas) no EconomyService.
- **2** payload web: música morta removida do export Web — first-load medido
  57,9 MB → 32,4 MB gzip (ver `WEB_SLIM.md`).
- **3b** premiação de temporada automática (fecha + liquida no job diário).
- **3c** companion multi-thread + hook de alerta/uptime opt-in.
- **3a** scaffold de i18n pt-BR (CSV + TranslationServer + `tr()` nas strings de
  código de login/conta/chefe/AFK).

O que **depende de terceiros** e por isso NÃO foi (nem pode ser) codado aqui.

## 1. Jurídico / fiscal (advogado + contador)
- **CNPJ/MEI/Simples** como pessoa jurídica emissora (jogo pago/compra in-app é
  atividade econômica). NF-e para as compras (se aplicável ao modelo).
- **Texto final** de Termos de Uso + Política de Privacidade **revisados por
  advogado** alinhados à LGPD e ao CDC. `data/db/agreement.json` ainda traz o
  texto herdado ("operates under U.S. law") — **trocar por jurisdição brasileira**
  e, ao publicar, bump `NetworkCommons.AgreementTosVersion/AgreementPrivacyVersion`
  (isso força re-aceite dos ativos). As versões ficam gravadas por conta
  (`account.consent_*`).
- **Classificação indicativa (CLASSIND/ERB)** para o país-alvo antes de monetizar
  público menor.

## 2. Pagamentos (onboarding de gateway)
- **Pix-first + cartão 3DS** (recomendação `MONETIZATION.md`). Abrir conta em um
  PSP (Stripe/Asaas/Efí/Mercado Pago…), obter **`whsec_…`** do endpoint de
  webhook e configurar `SHAMBLETA_WEBHOOK_PROVIDER=stripe` +
  `SHAMBLETA_STRIPE_WEBHOOK_SECRET` (o companion é fail-closed sem isso).
- **Catálogo real**: publicar os SKUs/precos em `SHAMBLETA_CATALOG_FILE` (JSON)
  igualando preço anunciado = cobrado; o `DEFAULT_CATALOG` é placeholder.
- **Checkout "comprar gems"** no cliente: hoje só há o caminho de gasto de gems
  (Shop). Falta a tela de compra que cria a sessão de pagamento no PSP e guarda o
  `client_reference_id=<account_id>` + `metadata.shambleta_sku` (o normalizador
  do webhook já consome esses campos). O grant entra pelo `grant_queue` idempotente.
- **Reembolso do dinheiro**: `RequestGemRefund` reverte as gems + marca
  `grant_queue.status='refunded'`; falta o companion chamar a API de refund do
  PSP ao ver esse estado (exige a conta do gateway).

## 3. Operação
- **Backups offsite testados**: `SHAMBLETA_OFFSITE_BACKUPS` + restore probe já
  existem; apontar para S3/objeto e fazer **restore de verdade** em ambiente
  isolado (provar RPO/RTO).
- **Alertas/uptime**: setar `SHAMBLETA_ALERT_WEBHOOK` (healthchecks/Discord).
  Sugerido: um ping periódico externo ao `/health` do companion (dead-man's switch).
- **Promoção do companion**: reescrever em Go/Node + **Postgres** quando o CCU
  exigir (hoje SQLite/WAL single-node — `ARCHITECTURE §11`). A tabela
  `grant_queue` e a idempotência não mudam.
- **Medição de KPIs do beta**: D7 ≥ 20%, conversão ≥ 2%, ARPPU ≥ R$ 25,
  custo infra, ±15%/sem em faucet/sink — os dados já saem do `/metrics` do
  companion (D1, retention, gems mint/burn, trades, fees, VIP, settles). Requer
  jogadores reais no beta aberto.

## 4. QA web (só em navegador — não dá pra fechar headless)
- Smoke pós-deploy: primeiro load real (confirmar ~32 MB e tempo de boot), WSS,
  duelo de boss **ao vivo** na tela, `Formation` read-back, abrir baú, comprar
  VIP, fluxo de consentimento/cadastro, botão de exclusão de conta, idioma pt-BR
  via `TranslationServer.set_locale`.
- **Para bater <25 MB**: as alavancas de `WEB_SLIM.md` (re-compressão de
  texturas, pack de áudio remoto) exigem QA visual.

## 5. Git
Há commits locais ainda **não enviados** ao remoto (`SOM-IDLE: …`). Fazer
`git push` quando o fluxo de branch/revisão estiver definido (nunca foi
autorizado nesta esteira).
