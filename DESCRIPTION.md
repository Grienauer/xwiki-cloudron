XWiki is a free and open source, Java-based enterprise wiki platform with a
strong focus on extensibility. It offers structured content, powerful in-place
WYSIWYG editing, application development on top of the wiki, fine-grained rights
management and a Confluence import - which makes it a common self-hosted
Confluence replacement.

This package wraps the official `xwiki` Docker image (Tomcat + PostgreSQL
flavour) so it runs inside Cloudron's managed environment: the database is
provided by the Cloudron PostgreSQL addon, authentication is wired to the
Cloudron user directory over LDAP (your Cloudron users can log in directly),
all state lives in the app's backed-up `/app/data` volume, and TLS / domain /
backups are handled by Cloudron.
