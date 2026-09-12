-- SOM-IDLE: conformidade LGPD (trilho jurídico — parte de código).
-- (a) Consentimento afirmativo no cadastro: versão dos textos aceitos + quando +
--     de onde (IP) — base legal para tratar e-mail/IP/telemetria.
-- (b) Direito ao esquecimento (art. 18): status da conta para o fluxo de
--     exclusão/anonimização. O ledger financeiro continua append-only (retenção
--     fiscal); anonimizar preserva account_id como pseudônimo.
ALTER TABLE account ADD COLUMN consent_tos_version TEXT NOT NULL DEFAULT '';
ALTER TABLE account ADD COLUMN consent_privacy_version TEXT NOT NULL DEFAULT '';
ALTER TABLE account ADD COLUMN consent_timestamp INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN consent_ip TEXT NOT NULL DEFAULT '';
-- status: 0 = ativa · 1 = agendada p/ exclusão · 2 = anonimizada/excluída
ALTER TABLE account ADD COLUMN status INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN purged_at INTEGER NOT NULL DEFAULT 0;
