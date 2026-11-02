CREATE TABLE `account` (
	`id` text PRIMARY KEY NOT NULL,
	`accountId` text NOT NULL,
	`providerId` text NOT NULL,
	`userId` text NOT NULL,
	`accessToken` text,
	`refreshToken` text,
	`idToken` text,
	`accessTokenExpiresAt` integer,
	`refreshTokenExpiresAt` integer,
	`scope` text,
	`password` text,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `account_user_idx` ON `account` (`userId`);--> statement-breakpoint
CREATE TABLE `asset` (
	`workspaceId` text NOT NULL,
	`hash` text NOT NULL,
	`size` integer NOT NULL,
	`type` text NOT NULL,
	`ready` integer DEFAULT false NOT NULL,
	`createdAt` integer NOT NULL,
	PRIMARY KEY(`workspaceId`, `hash`),
	FOREIGN KEY (`workspaceId`) REFERENCES `organization`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `document` (
	`id` text PRIMARY KEY NOT NULL,
	`workspaceId` text NOT NULL,
	`kind` text DEFAULT 'shared' NOT NULL,
	`name` text NOT NULL,
	`headVersionId` text,
	`sizeBytes` integer DEFAULT 0 NOT NULL,
	`createdBy` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`deletedAt` integer,
	FOREIGN KEY (`workspaceId`) REFERENCES `organization`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`createdBy`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `document_ws_idx` ON `document` (`workspaceId`,`deletedAt`,`updatedAt`);--> statement-breakpoint
CREATE TABLE `invitation` (
	`id` text PRIMARY KEY NOT NULL,
	`organizationId` text NOT NULL,
	`email` text NOT NULL,
	`role` text,
	`teamId` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`expiresAt` integer NOT NULL,
	`createdAt` integer NOT NULL,
	`inviterId` text NOT NULL,
	FOREIGN KEY (`organizationId`) REFERENCES `organization`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`inviterId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `member` (
	`id` text PRIMARY KEY NOT NULL,
	`organizationId` text NOT NULL,
	`userId` text NOT NULL,
	`role` text DEFAULT 'member' NOT NULL,
	`createdAt` integer NOT NULL,
	FOREIGN KEY (`organizationId`) REFERENCES `organization`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `member_user_idx` ON `member` (`userId`);--> statement-breakpoint
CREATE INDEX `member_org_idx` ON `member` (`organizationId`);--> statement-breakpoint
CREATE TABLE `organization` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`slug` text NOT NULL,
	`logo` text,
	`createdAt` integer NOT NULL,
	`metadata` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `organization_slug_unique` ON `organization` (`slug`);--> statement-breakpoint
CREATE TABLE `session` (
	`id` text PRIMARY KEY NOT NULL,
	`expiresAt` integer NOT NULL,
	`token` text NOT NULL,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL,
	`ipAddress` text,
	`userAgent` text,
	`userId` text NOT NULL,
	`activeOrganizationId` text,
	`activeTeamId` text,
	FOREIGN KEY (`userId`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `session_token_unique` ON `session` (`token`);--> statement-breakpoint
CREATE INDEX `session_user_idx` ON `session` (`userId`);--> statement-breakpoint
CREATE TABLE `share_link` (
	`id` text PRIMARY KEY NOT NULL,
	`docId` text NOT NULL,
	`workspaceId` text NOT NULL,
	`tokenHash` text NOT NULL,
	`tokenSealed` text NOT NULL,
	`role` text DEFAULT 'view' NOT NULL,
	`visibility` text DEFAULT 'link' NOT NULL,
	`allowDownload` integer DEFAULT false NOT NULL,
	`allowEmbed` integer DEFAULT false NOT NULL,
	`expiresAt` integer,
	`revokedAt` integer,
	`viewCount` integer DEFAULT 0 NOT NULL,
	`createdBy` text NOT NULL,
	`createdAt` integer NOT NULL,
	FOREIGN KEY (`docId`) REFERENCES `document`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`createdBy`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `share_link_token_idx` ON `share_link` (`tokenHash`);--> statement-breakpoint
CREATE INDEX `share_link_doc_idx` ON `share_link` (`docId`);--> statement-breakpoint
CREATE TABLE `user` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`email` text NOT NULL,
	`emailVerified` integer DEFAULT false NOT NULL,
	`image` text,
	`createdAt` integer NOT NULL,
	`updatedAt` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `user_email_unique` ON `user` (`email`);--> statement-breakpoint
CREATE TABLE `verification` (
	`id` text PRIMARY KEY NOT NULL,
	`identifier` text NOT NULL,
	`value` text NOT NULL,
	`expiresAt` integer NOT NULL,
	`createdAt` integer,
	`updatedAt` integer
);
--> statement-breakpoint
CREATE TABLE `version` (
	`id` text PRIMARY KEY NOT NULL,
	`docId` text NOT NULL,
	`workspaceId` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`penHash` text NOT NULL,
	`manifest` text NOT NULL,
	`sizeBytes` integer NOT NULL,
	`createdBy` text NOT NULL,
	`createdAt` integer NOT NULL,
	`committedAt` integer,
	FOREIGN KEY (`docId`) REFERENCES `document`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`createdBy`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `version_doc_idx` ON `version` (`docId`,`status`);--> statement-breakpoint
CREATE TABLE `workspace_plan` (
	`workspaceId` text PRIMARY KEY NOT NULL,
	`plan` text DEFAULT 'free' NOT NULL,
	`entitlements` text DEFAULT '{}' NOT NULL,
	`updatedAt` integer NOT NULL,
	FOREIGN KEY (`workspaceId`) REFERENCES `organization`(`id`) ON UPDATE no action ON DELETE cascade
);
