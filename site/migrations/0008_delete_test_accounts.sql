-- Data, not schema: queue every test account for deletion. Test accounts use the reserved
-- `.test` domain agentic-design.test, which no real person can own (RFC 2606); one was left
-- behind by a crashed end-to-end run. The hourly job (src/account.ts) purges them.
INSERT INTO `account_deletion` (`userId`, `reason`, `requestedAt`)
SELECT `id`, 'test account (@agentic-design.test)', unixepoch() FROM `user`
WHERE `email` LIKE '%@agentic-design.test'
  AND NOT EXISTS (SELECT 1 FROM `account_deletion` WHERE `account_deletion`.`userId` = `user`.`id`);
