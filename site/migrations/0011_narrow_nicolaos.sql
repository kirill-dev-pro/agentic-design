CREATE TABLE `comment` (
	`id` text PRIMARY KEY NOT NULL,
	`docId` text NOT NULL,
	`threadId` text,
	`authorId` text NOT NULL,
	`body` text NOT NULL,
	`anchor` text,
	`createdAt` integer NOT NULL,
	`editedAt` integer,
	`resolvedAt` integer,
	`resolvedBy` text,
	FOREIGN KEY (`docId`) REFERENCES `document`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`authorId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `comment_doc_idx` ON `comment` (`docId`,`createdAt`);--> statement-breakpoint
CREATE INDEX `comment_thread_idx` ON `comment` (`threadId`);