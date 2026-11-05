CREATE TABLE `doc_invite` (
	`id` text PRIMARY KEY NOT NULL,
	`docId` text NOT NULL,
	`email` text NOT NULL,
	`role` text NOT NULL,
	`tokenHash` text NOT NULL,
	`tokenSealed` text NOT NULL,
	`invitedBy` text NOT NULL,
	`createdAt` integer NOT NULL,
	`expiresAt` integer NOT NULL,
	`acceptedAt` integer,
	`acceptedBy` text,
	`revokedAt` integer,
	FOREIGN KEY (`docId`) REFERENCES `document`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`invitedBy`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `doc_invite_token_idx` ON `doc_invite` (`tokenHash`);--> statement-breakpoint
CREATE INDEX `doc_invite_doc_idx` ON `doc_invite` (`docId`);--> statement-breakpoint
CREATE TABLE `doc_member` (
	`docId` text NOT NULL,
	`userId` text NOT NULL,
	`role` text NOT NULL,
	`invitedBy` text,
	`createdAt` integer NOT NULL,
	PRIMARY KEY(`docId`, `userId`),
	FOREIGN KEY (`docId`) REFERENCES `document`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `doc_member_user_idx` ON `doc_member` (`userId`);