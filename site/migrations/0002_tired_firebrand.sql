CREATE TABLE `view_metric` (
	`day` text NOT NULL,
	`webgpu` integer NOT NULL,
	`platform` text NOT NULL,
	`standalone` integer NOT NULL,
	`count` integer DEFAULT 0 NOT NULL,
	PRIMARY KEY(`day`, `webgpu`, `platform`, `standalone`)
);
