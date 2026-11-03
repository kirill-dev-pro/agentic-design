CREATE TABLE `app_auth_code` (
	`codeHash` text PRIMARY KEY NOT NULL,
	`userId` text NOT NULL,
	`challenge` text NOT NULL,
	`device` text NOT NULL,
	`expiresAt` integer NOT NULL,
	`usedAt` integer,
	`createdAt` integer NOT NULL,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
