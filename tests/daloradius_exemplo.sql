-- Esquema mínimo do daloRADIUS (FreeRADIUS 3 + userinfo) com dados de exemplo para os testes.

CREATE TABLE IF NOT EXISTS radacct (
  radacctid bigint(21) NOT NULL AUTO_INCREMENT,
  acctsessionid varchar(64) NOT NULL DEFAULT '',
  acctuniqueid varchar(32) NOT NULL DEFAULT '',
  username varchar(64) NOT NULL DEFAULT '',
  groupname varchar(64) NOT NULL DEFAULT '',
  realm varchar(64) DEFAULT '',
  nasipaddress varchar(15) NOT NULL DEFAULT '',
  nasportid varchar(32) DEFAULT NULL,
  nasporttype varchar(32) DEFAULT NULL,
  acctstarttime datetime NULL DEFAULT NULL,
  acctupdatetime datetime NULL DEFAULT NULL,
  acctstoptime datetime NULL DEFAULT NULL,
  acctinterval int(12) DEFAULT NULL,
  acctsessiontime int(12) unsigned DEFAULT NULL,
  acctauthentic varchar(32) DEFAULT NULL,
  connectinfo_start varchar(50) DEFAULT NULL,
  connectinfo_stop varchar(50) DEFAULT NULL,
  acctinputoctets bigint(20) DEFAULT NULL,
  acctoutputoctets bigint(20) DEFAULT NULL,
  calledstationid varchar(50) NOT NULL DEFAULT '',
  callingstationid varchar(50) NOT NULL DEFAULT '',
  acctterminatecause varchar(32) NOT NULL DEFAULT '',
  servicetype varchar(32) DEFAULT NULL,
  framedprotocol varchar(32) DEFAULT NULL,
  framedipaddress varchar(15) NOT NULL DEFAULT '',
  framedipv6address varchar(45) NOT NULL DEFAULT '',
  framedipv6prefix varchar(45) NOT NULL DEFAULT '',
  framedinterfaceid varchar(44) NOT NULL DEFAULT '',
  delegatedipv6prefix varchar(45) NOT NULL DEFAULT '',
  class varchar(64) DEFAULT NULL,
  PRIMARY KEY (radacctid),
  UNIQUE KEY acctuniqueid (acctuniqueid),
  KEY username (username),
  KEY framedipaddress (framedipaddress),
  KEY framedipv6address (framedipv6address),
  KEY framedipv6prefix (framedipv6prefix),
  KEY framedinterfaceid (framedinterfaceid),
  KEY delegatedipv6prefix (delegatedipv6prefix),
  KEY acctsessionid (acctsessionid),
  KEY acctsessiontime (acctsessiontime),
  KEY acctstarttime (acctstarttime),
  KEY acctinterval (acctinterval),
  KEY acctstoptime (acctstoptime),
  KEY nasipaddress (nasipaddress),
  INDEX bulk_close (acctstoptime, nasipaddress, acctstarttime)
);

CREATE TABLE IF NOT EXISTS radcheck (
  id int(11) unsigned NOT NULL AUTO_INCREMENT,
  username varchar(64) NOT NULL DEFAULT '',
  attribute varchar(64)  NOT NULL DEFAULT '',
  op char(2) NOT NULL DEFAULT '==',
  value varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY  (id),
  KEY username (username(32))
);

CREATE TABLE IF NOT EXISTS radgroupcheck (
  id int(11) unsigned NOT NULL AUTO_INCREMENT,
  groupname varchar(64) NOT NULL DEFAULT '',
  attribute varchar(64)  NOT NULL DEFAULT '',
  op char(2) NOT NULL DEFAULT '==',
  value varchar(253)  NOT NULL DEFAULT '',
  PRIMARY KEY  (id),
  KEY groupname (groupname(32))
);

CREATE TABLE IF NOT EXISTS radgroupreply (
  id int(11) unsigned NOT NULL AUTO_INCREMENT,
  groupname varchar(64) NOT NULL DEFAULT '',
  attribute varchar(64)  NOT NULL DEFAULT '',
  op char(2) NOT NULL DEFAULT '=',
  value varchar(253)  NOT NULL DEFAULT '',
  PRIMARY KEY  (id),
  KEY groupname (groupname(32))
);

CREATE TABLE IF NOT EXISTS radreply (
  id int(11) unsigned NOT NULL AUTO_INCREMENT,
  username varchar(64) NOT NULL DEFAULT '',
  attribute varchar(64) NOT NULL DEFAULT '',
  op char(2) NOT NULL DEFAULT '=',
  value varchar(253) NOT NULL DEFAULT '',
  PRIMARY KEY  (id),
  KEY username (username(32))
);

CREATE TABLE IF NOT EXISTS radusergroup (
  id int(11) unsigned NOT NULL AUTO_INCREMENT,
  username varchar(64) NOT NULL DEFAULT '',
  groupname varchar(64) NOT NULL DEFAULT '',
  priority int(11) NOT NULL DEFAULT '1',
  PRIMARY KEY  (id),
  KEY username (username(32))
);

CREATE TABLE IF NOT EXISTS radpostauth (
  id int(11) NOT NULL AUTO_INCREMENT,
  username varchar(64) NOT NULL DEFAULT '',
  pass varchar(64) NOT NULL DEFAULT '',
  reply varchar(32) NOT NULL DEFAULT '',
  authdate timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  class varchar(64) NOT NULL DEFAULT '',
  PRIMARY KEY  (id)
);

CREATE TABLE IF NOT EXISTS nas (
  id int(10) NOT NULL AUTO_INCREMENT,
  nasname varchar(128) NOT NULL,
  shortname varchar(32),
  type varchar(30) DEFAULT 'other',
  ports int(5),
  secret varchar(60) DEFAULT 'secret' NOT NULL,
  server varchar(64),
  community varchar(50),
  description varchar(200) DEFAULT 'RADIUS Client',
  require_ma varchar(4) DEFAULT 'auto',
  limit_proxy_state varchar(4) DEFAULT 'auto',
  PRIMARY KEY (id),
  KEY nasname (nasname)
);

CREATE TABLE `userinfo` (
  `id` INT(11) UNSIGNED NOT NULL AUTO_INCREMENT,
  `username` VARCHAR(128) DEFAULT NULL,
  `firstname` VARCHAR(200) DEFAULT NULL,
  `lastname` VARCHAR(200) DEFAULT NULL,
  `email` VARCHAR(200) DEFAULT NULL,
  `department` VARCHAR(200) DEFAULT NULL,
  `company` VARCHAR(200) DEFAULT NULL,
  `workphone` VARCHAR(200) DEFAULT NULL,
  `homephone` VARCHAR(200) DEFAULT NULL,
  `mobilephone` VARCHAR(200) DEFAULT NULL,
  `address` VARCHAR(200) DEFAULT NULL,
  `city` VARCHAR(200) DEFAULT NULL,
  `state` VARCHAR(200) DEFAULT NULL,
  `country` VARCHAR(100) DEFAULT NULL,
  `zip` VARCHAR(200) DEFAULT NULL,
  `notes` VARCHAR(200) DEFAULT NULL,
  `changeuserinfo` VARCHAR(128) DEFAULT NULL,
  `portalloginpassword` VARCHAR(255) DEFAULT '',
  `enableportallogin` INT(32) DEFAULT '0',
  `creationdate` DATETIME DEFAULT '0000-00-00 00:00:00',
  `creationby` VARCHAR(128) DEFAULT NULL,
  `updatedate` DATETIME DEFAULT '0000-00-00 00:00:00',
  `updateby` VARCHAR(128) DEFAULT NULL,
  PRIMARY KEY  (`id`),
  KEY `username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ------------------------------------------------------------------
-- Dados de exemplo (equipe com acesso aos equipamentos)
-- ------------------------------------------------------------------
INSERT INTO radcheck (username, attribute, op, value) VALUES
  ('joao',    'Cleartext-Password', ':=', 'SenhaJoao#2024'),
  ('maria',   'Cleartext-Password', ':=', 'SenhaMaria!2024'),
  ('carlos',  'Cleartext-Password', ':=', 'SenhaCarlos2024'),
  ('carlos',  'Auth-Type',          ':=', 'Reject'),
  ('ana',     'Cleartext-Password', ':=', 'SenhaAna2024'),
  ('ana',     'Expiration',         ':=', '01 Jan 2020'),
  ('pedro',   'MD5-Password',       ':=', '5f4dcc3b5aa765d61d8327deb882cf99'),
  ('tecnico1','Cleartext-Password', ':=', 'campo;2024'),
  ('tecnico1','Simultaneous-Use',   ':=', '1');

INSERT INTO radreply (username, attribute, op, value) VALUES
  ('maria', 'Reply-Message', ':=', 'Bem-vinda, Maria');

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
  ('noc',     'Service-Type',          ':=', 'Administrative-User'),
  ('noc',     'Mikrotik-Group',        ':=', 'full'),
  ('noc',     'Huawei-Exec-Privilege', ':=', '15'),
  ('noc',     'Cisco-AVPair',          '+=', 'shell:priv-lvl=15'),
  ('suporte', 'Mikrotik-Group',        ':=', 'read'),
  ('suporte', 'Huawei-Exec-Privilege', ':=', '1'),
  ('suporte', 'Fabricante-Desconhecido-Attr', ':=', 'x'),
  ('campo',   'Mikrotik-Group',        ':=', 'write');

INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES
  ('campo', 'Login-Time', ':=', 'Wk0800-1800');

INSERT INTO radusergroup (username, groupname, priority) VALUES
  ('joao',     'noc',     1),
  ('maria',    'suporte', 1),
  ('carlos',   'noc',     1),
  ('ana',      'suporte', 1),
  ('pedro',    'suporte', 1),
  ('tecnico1', 'campo',   2);

INSERT INTO userinfo (username, firstname, lastname, email, department, mobilephone) VALUES
  ('joao',  'João',  'Silva',  'joao@exemplo.net.br',  'NOC',     '+55 11 90000-0001'),
  ('maria', 'Maria', 'Souza',  'maria@exemplo.net.br', 'Suporte', '+55 11 90000-0002');

-- Equipamentos: a rede 172.16.0.0/12 cobre o container de teste (bridge do Docker).
INSERT INTO nas (nasname, shortname, type, secret, description) VALUES
  ('172.16.0.0/12', 'mk-teste',  'mikrotik', 'SegredoDoNAS123', 'Mikrotik de teste'),
  ('10.10.0.1',     'olt-huawei','huawei',   'OutroSegredo456', 'OLT Huawei sede');

INSERT INTO radpostauth (username, pass, reply, authdate) VALUES
  ('maria', '0x01a1b2c3d4e5f60718293a4b5c6d7e8f90', 'Access-Accept', NOW() - INTERVAL 3 DAY);
