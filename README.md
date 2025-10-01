# Stupidly Simple Static Site Generator (S4G)

This is stupid. And simple.  And it generates static sites.  In Bash. Yikes. I'm only sharing it here so the world knows how bad of an idea this is.

## Setup

* clone the repo. 
* `chmod +x s4g.sh`
* `./s4g.sh init` (answer the questions, the only one you likely care about is Site Title)
* (optional) `python3 -m http.server 8000`

Bask in the glory of your new site.

## Main commands

* `./s4g.sh init` - Asks you a couple questions (except for site title, just accept the defaults...you'll dig it), then generates the bare bones structure of the site:
  ```
  config.yml
  sitemap.xml
  index.html
  --css
    style.css
    critical.css
  --feeds
    feed.xml
    feed.json
  --posts
    --my-first-post
      index.md
  --tags
    index.html
    --example
      index.html  
  --templates
    header.html
    footer.html
  ```

* `./s4g.sh scaffold` - Scaffolds a post. Takes *title* as an argument. so, `./s4g.sh scaffold "My Summer Vacation"` creates a new folder in `posts` called `my-summer-vacation` with an index.md in there. Edit that and tell us all what you did last summer, little Johnny.
* `./s4g.sh build` - Builds the site.  Basically, it goes through each post in `/posts`, converts the .md to .html by wrapping the contents of the markdown in the header and footer templates.  It also keeps track of the tags and generates tag pages. It also generates the RSS feeds and the sitemap.xml. You'll want to run `./s4g.sh build` whenever you update a .md file or style.css.

There's nav in header.html. You need to manually edit it.  I'm not going to decide for you what goes in your nav. __MAKE IT YOURS__!

If you edit your style.css (recommended), during the build process it gets a unique filename (for cache-busting purposes) and jammed into the header.

A lot of stuff is manual.  That's intentional.  I'm old.  I like doing things the hard way.

You can then upload this entire folder to a web server somewhere or do `python3 -m http.server 8000` or whatever to view your site.  Note how super fast it is.

There's some other things

## Metadata

Each post .md file has some metadata at the top:

```
---
title: my summer photos
description:
We had some fun this summer.

![Me during hoagie fest](/posts/my-summer-photos/photos/thumbs/IMG_3535.jpeg)
date: 2025-09-27
tags: photos, summer, hoagiefest, wawa
section: photos
hide_from_feed: 0
photo_page: 1
---
```

some of these fields (title, date, tags) are obvious. others warrant some explaining:

* __description__ will accept markdown.  This is what gets output on the main /index.html and on the tag pages (like /tags/summer/index.html).
* __section__ whatever you add here just gets added as a class to the body tag of that page...so `<body class="photos">`
* __hide_from_feed__ set this to __1__ if you don't want this to display on the main /index.html...useful for about pages or the like.
* __photo_page__ set this to __1__ if you want the page to include a grid of photos (placed as a sub-folder of your post folder.  So `/posts/my-summer-vacation/photos/`  The script will shrink them down and create a `thumbs` sub-folder in there.  The filenames are used as captions.  not ideal, but, yeah.)  You could always make the grid yourself in your .md file if you want to get fancy.



## Why

I'm stupid and simple. Honestly, I just like HTML and I don't want package managers, databases, build pipelines, upgrade paths, security patches, node versions, yarn whatever...all the shit that is associated with basically _any_ kind of web development in this day and age.  I just want a way to write a post and build a site...I also want it to be accessible.  I also don't want any javascript.  You can add whatever you want.  All this stupid thing does is generate HTML files.  In a really inefficient and stupid way.  With Bash. It works on my machine. It may or may not work on yours. Patches welcome.



