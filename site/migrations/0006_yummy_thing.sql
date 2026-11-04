ALTER TABLE `document` ADD `headSeq` integer;--> statement-breakpoint
ALTER TABLE `version` ADD `kind` text DEFAULT 'upload' NOT NULL;--> statement-breakpoint
ALTER TABLE `version` ADD `seq` integer;