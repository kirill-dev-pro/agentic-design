CREATE TABLE `account_deletion` (
	`userId` text PRIMARY KEY NOT NULL,
	`reason` text,
	`requestedAt` integer NOT NULL,
	`doneAt` integer
);
