# Nginx web server

## Goal

Serve my own static site from the homelab server over HTTP on the LAN.

## Install

```bash
sudo apt update && sudo apt install nginx
systemctl status nginx
```

## Site setup

- Web root: `/var/www/mysite`
- Server block: see [`configs/nginx/mysite`](../configs/nginx/mysite)
- Enabled with:

```bash
sudo ln -s /etc/nginx/sites-available/mysite /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

- Verified from the server:

```
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html
```

- Verified from my laptop by browsing to `http://192.168.1.200`.

## Reading logs

My server block writes to site-specific logs, not the default ones:

- Access log: `/var/log/nginx/mysite.access.log`
- Error log: `/var/log/nginx/mysite.error.log`

```bash
sudo tail -n 5 /var/log/nginx/mysite.access.log
sudo tail -f /var/log/nginx/mysite.error.log
```

## 404 vs 403

**404 Not Found**: the file or path doesn't exist.

- How I reproduced it: requested a path that doesn't exist.

```bash
curl -I http://localhost/nope
```

- Response: `HTTP/1.1 404 Not Found`
- Access log:

```
::1 - - [19/Oct/2026:11:27:14 +0800] "HEAD /nope HTTP/1.1" 404 0 "-" "curl/8.5.0"
```

- Error log: nothing. `try_files $uri $uri/ =404` returns the 404 quietly, so it only shows up in the access log.

**403 Forbidden**: the file exists, but Nginx isn't allowed to read it.

- How I reproduced it: removed all permissions on the page, then requested it.

```bash
sudo chmod 000 /var/www/mysite/index.html
curl -I http://localhost/
```

- Response: `HTTP/1.1 403 Forbidden`
- Access log:

```
::1 - - [19/Oct/2026:11:28:02 +0800] "HEAD / HTTP/1.1" 403 0 "-" "curl/8.5.0"
```

- Error log:

```
2026/10/19 11:28:02 [error] 3329#3329: *14 open() "/var/www/mysite/index.html" failed (13: Permission denied), client: ::1, server: _, request: "HEAD / HTTP/1.1", host: "localhost"
```

- Cleanup: restored the permissions afterwards.

```bash
sudo chmod 644 /var/www/mysite/index.html
```

**How the logs told them apart:** both show up in the access log with a different status code (404 vs 403), but only the 403 writes to the error log, with `Permission denied` naming the exact file. A 404 leaves no error entry because Nginx simply didn't find anything to serve.

## Breaking it on purpose

- **What I broke:** misspelled the `listen` directive as `lisen` in `/etc/nginx/sites-available/mysite`.
- **What `sudo nginx -t` told me:**

```
2026/10/19 11:07:03 [emerg] 3708#3708: unknown directive "lisen" in /etc/nginx/sites-enabled/mysite:2
nginx: configuration file /etc/nginx/nginx.conf test failed
```

- **How I fixed it:** reopened the file with `sudo nano /etc/nginx/sites-available/mysite`, corrected `lisen` back to `listen`, and re-ran the test:

```
$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

`nginx -t` checks the config without touching the running site, so a typo gets caught before it can take the server down.

## What I learned

- 404 means the file doesn't exist; 403 means it exists but Nginx isn't allowed to read it. The access log shows the status code, and the error log explains why.
- Always run `sudo nginx -t` before reloading. It names the file and line number of the mistake.
- At first I tailed the default `/var/log/nginx/error.log` and saw nothing useful, because my server block sends this site's logs to `mysite.error.log`. Check the config to find out where a site actually logs.
