CREATE TABLE `auth_trace` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`at` integer NOT NULL,
	`step` text NOT NULL,
	`provider` text,
	`asked` text,
	`status` integer NOT NULL,
	`location` text,
	`hadStateCookie` integer NOT NULL,
	`hadState` integer NOT NULL
);
