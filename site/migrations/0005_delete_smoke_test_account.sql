-- Data, not schema: queue the production smoke-test account of the M1 release for deletion
-- (its password was random and not kept). The hourly job (src/account.ts) purges it. A no-op
-- where the account does not exist.
INSERT INTO `account_deletion` (`userId`, `reason`, `requestedAt`)
SELECT `id`, 'M1 smoke-test account', unixepoch() FROM `user`
WHERE `email` = 'smoke-1793707234995-114c25@agentic-design.test'
  AND NOT EXISTS (SELECT 1 FROM `account_deletion` WHERE `account_deletion`.`userId` = `user`.`id`);
