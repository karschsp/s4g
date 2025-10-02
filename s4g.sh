#!/opt/homebrew/bin/bash
set -e

CONFIG_FILE="config.yml"

# -----------------------------
# UTILS / PARSERS 
# -----------------------------
render_markdown() {
    local md="$1"
    if [[ -z "$md" ]]; then
        echo ""
        return
    fi
    # Use a here-string to pass to pandoc
    echo "$md" | pandoc --from=markdown_phpextra -t html | tr -d '\n'
}


extract_description() {
    local md_file="$1"
    awk '
        BEGIN { in_fm=0; in_desc=0 }
        /^---$/ { in_fm = 1 - in_fm; next }
        in_fm && /^description:/ {
            in_desc=1
            sub(/^description:[[:space:]]*/, "")
            if (length($0)) print $0
            next
        }
        in_desc && /^[a-zA-Z0-9_]+:/ { exit }  # next key → stop
        in_desc { print }
    ' "$md_file"
}


read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    # Simple YAML parser for key: value (no nesting) - preserved exactly
    while IFS=":" read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue  # skip comments
        eval "${key^^}=\"$value\""      # uppercase variable names
    done < "$CONFIG_FILE"

    # ensure sensible defaults
    INDEX_FILE=${INDEX_FILE:-index.html}
    POSTS_DIR=${POSTS_DIR:-posts}
    TEMPLATES_DIR=${TEMPLATES_DIR:-templates}
    FEED_DIR=${FEED_DIR:-feeds}
    TAGS_DIR=${TAGS_DIR:-tags}
    CRITICAL_CSS_FILE=${CRITICAL_CSS_FILE:-css/critical.css}
    SITE_TITLE=${SITE_TITLE:-Site Title}
    BASE_URL=${BASE_URL:-http://localhost:8000}
    return 0
}

slugify() {
    local s="$1"
    s="${s,,}"                 # lowercase
    s="${s// /-}"              # spaces → dashes
    s="$(echo "$s" | sed 's/[^a-z0-9-]//g')"  # remove invalid chars
    echo "$s"
}

minify_css() {
    local input_file="$1"
    local output_file="$2"

    awk '
    BEGIN { in_comment=0 }
    {
        line=$0
        # Handle start of comment
        while (match(line, /\/\*/)) {
            start=RSTART
            if (match(substr(line, start), /\*\//)) {
                # comment starts and ends on same line
                end=start+RLENGTH-1
                line=substr(line,1,start-1) substr(line,end+1)
            } else {
                # comment starts but doesn’t end on this line
                line=substr(line,1,start-1)
                in_comment=1
                break
            }
        }
        if (!in_comment) print line
        else if (match(line, /\*\//)) {
            # comment closes mid-line
            end=RSTART+RLENGTH-1
            line=substr(line,end+1)
            in_comment=0
            print line
        }
    }' "$input_file" \
    | sed 's/[[:space:]]\{2,\}/ /g' \
    > "$output_file"

    echo "Minified $input_file -> $output_file"
}

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

strip_frontmatter() {
    sed '1,/^---$/d' "$1"
}

# -----------------------------
# Parse frontmatter (ignore multiline description)
# returns: title|date|tags|hide_from_feed|photo_page|section
# -----------------------------
# returns: title|date|tags|hide_from_feed|photo_page|section
parse_frontmatter() {
    local file="$1"
    awk '
        function trim(s) {
            sub(/^[ \t\r\n]+/, "", s);
            sub(/[ \t\r\n]+$/, "", s);
            return s;
        }
        /^---$/ {i++; next}
        i==1 && /^title: /        {title=trim(substr($0,8))}
        i==1 && /^date: /         {date=trim(substr($0,7))}
        i==1 && /^tags: /         {tags=trim(substr($0,6))}
        i==1 && /^hide_from_feed:/ {hff=trim(substr($0,16))}
        i==1 && /^photo_page:/    {pp=trim(substr($0,13))}
        i==1 && /^section:/       {sec=trim(substr($0,9))}
        END {print title "|" date "|" tags "|" hff "|" pp "|" sec}
    ' "$file"
}


# RFC2822 date formatting (uses gdate if available; falls back to date -R)
format_rfc2822() {
    local dt="$1"
    if command -v gdate >/dev/null 2>&1; then
        gdate -R -d "$dt"
    else
        # fallback: try GNU-style date, else use date -R for now (approx)
        if date -R -d "$dt" >/dev/null 2>&1; then
            date -R -d "$dt"
        else
            echo "Warning: gdate not found; using date -R fallback (may differ)." >&2
            date -R
        fi
    fi
}

# -----------------------------
# SCAFFOLD (create a new markdown post)
# -----------------------------
scaffold_post() {
    local NEW_POST_TITLE="$*"
    if [[ -z "$NEW_POST_TITLE" ]]; then
        echo "Usage: $0 scaffold \"Post Title\""
        return 1
    fi

    # Ensure config loaded
    read_config || true

    POST_SLUG=$(slugify "$NEW_POST_TITLE")
    POST_PATH="$POSTS_DIR/$POST_SLUG"

    if [[ -d "$POST_PATH" ]]; then
        echo "Error: $POST_PATH already exists"
        return 1
    fi

    mkdir -p "$POST_PATH"
    cat > "$POST_PATH/index.md" <<EOF
---
title: $NEW_POST_TITLE
description:
date: $(date +%Y-%m-%d)
tags:
section:
hide_from_feed: 0
photo_page: 0
---
EOF

    echo "Scaffolded new post at $POST_PATH/index.md"
    return 0
}

# -----------------------------
# BUILD (recreate HTML, feeds, tags, sitemap)
# -----------------------------
build_site() {
    # load config (must exist)
    if ! read_config; then
        echo "Error: $CONFIG_FILE not found — cannot build."
        exit 1
    fi

    mkdir -p "$POSTS_DIR" "$TEMPLATES_DIR" "$FEED_DIR" "$TAGS_DIR"

    # ensure critical css exists so build doesn't blow up
    if [[ ! -f "$CRITICAL_CSS_FILE" ]]; then
        mkdir -p "$(dirname "$CRITICAL_CSS_FILE")"
        echo "/* critical css */" > "$CRITICAL_CSS_FILE"
    fi

    # -----------------------------
    # CONDITIONAL CACHEBUST CSS (preserve behavior)
    # -----------------------------
    CSS_SRC="css/style.css"
    EXISTING_MIN=$(ls css/style.*.min.css 2>/dev/null | head -n1 || true)

    TMP_MIN=$(mktemp)
    minify_css "$CSS_SRC" "$TMP_MIN"

    UPDATE_HEADER=0
    if [[ -z "$EXISTING_MIN" ]] || ! cmp -s "$TMP_MIN" "$EXISTING_MIN"; then
        CSS_SUFFIX=$(openssl rand -hex 4)
        CSS_OUT="css/style.${CSS_SUFFIX}.min.css"
        mv "$TMP_MIN" "$CSS_OUT"
        UPDATE_HEADER=1

        # Clean old minified files except the one we just created
        for f in css/style.*.min.css; do
            [[ "$f" != "$CSS_OUT" ]] && rm -f "$f"
        done
        echo "Created new CSS: $CSS_OUT"
    else
        rm "$TMP_MIN"
        CSS_SUFFIX=$(basename "$EXISTING_MIN" | sed -E 's/style\.([a-f0-9]+)\.min\.css/\1/')
        CSS_OUT="$EXISTING_MIN"
        echo "No changes in $CSS_SRC; using existing minified CSS."
    fi

    if [[ $UPDATE_HEADER -eq 1 ]]; then
        awk -v new_css="$CSS_SUFFIX" \
            '{ gsub(/style(\.[A-Za-z0-9]+)?\.min\.css/, "style." new_css ".min.css"); print }' \
            "$TEMPLATES_DIR/header.html" > "$TEMPLATES_DIR/header.tmp"

        mv "$TEMPLATES_DIR/header.tmp" "$TEMPLATES_DIR/header.html"
        echo "Updated $TEMPLATES_DIR/header.html to reference $CSS_OUT"
    fi

    # -----------------------------
    # BUILD POSTS LOOP (clean, full markdown support)
    # -----------------------------
    POST_ENTRIES=()
    declare -A TAG_MAP      # tag_slug -> lines of date|title|post_path|desc_html
    declare -A TAG_DISPLAY  # tag_slug -> display name

    for post in "$POSTS_DIR"/*; do
        [[ -d "$post" ]] || continue
        MD_FILE="$post/index.md"
        [[ -f "$MD_FILE" ]] || continue

        # Parse frontmatter (ignore description in Bash array)
        IFS='|' read -r title date tags hide_from_feed photo_page section <<< "$(parse_frontmatter "$MD_FILE")"

        # Extract and render description
        desc_md=$(extract_description "$MD_FILE")
        desc_html=$(render_markdown "$desc_md")

        # Strip frontmatter to get full post content
        CONTENT_MD=$(strip_frontmatter "$MD_FILE")
        CONTENT_HTML=$(echo "$CONTENT_MD" | pandoc --from=markdown_phpextra -t html)

        # PHOTO PAGE SUPPORT (unchanged)
        PHOTO_HTML=""
        if [[ "$photo_page" == "1" && -d "$post/photos" ]]; then
            thumbs_dir="$post/photos/thumbs"
            mkdir -p "$thumbs_dir"
            PHOTO_HTML="<div class='photo-gallery'>"
            for img in "$post/photos"/*.{jpg,jpeg,png,gif}; do
                [[ -f "$img" ]] || continue
                filename=$(basename "$img")
                thumb="$thumbs_dir/$filename"
                [[ ! -f "$thumb" || "$img" -nt "$thumb" ]] && convert "$img" -resize 400x400\> "$thumb"
                caption=$(basename "$filename" | sed -E 's/\.[^.]+$//' | sed -E 's/[-_]+/ /g')
                caption="$(tr '[:lower:]' '[:upper:]' <<< ${caption:0:1})${caption:1}"
                PHOTO_HTML+="
                <figure class='photo-item'>
                    <a href='/$post/photos/$filename' class='photo-link'>
                        <img src='/$post/photos/thumbs/$filename' alt='$caption'>
                    </a>
                    <figcaption>$caption</figcaption>
                </figure>"
            done
            PHOTO_HTML+="</div>"
        fi

        # Build full post HTML
        POST_BODY="<div class='header-row'><time>$date</time><h2 class='post-title'>$title</h2></div>
        <article class='post-body'>
            $CONTENT_HTML
            $PHOTO_HTML
            <div class='post-tags'><strong>Tags:</strong> "
        IFS=',' read -ra tag_array <<< "$tags"
        for t in "${tag_array[@]}"; do
            clean_tag=$(trim "$t")
            [[ -z "$clean_tag" ]] && continue
            tag_slug=$(slugify "$clean_tag")
            POST_BODY+="<a href='/$TAGS_DIR/${tag_slug}/' class='tag'>$clean_tag</a> "
            #TAG_DISPLAY["$tag_slug"]="$clean_tag"
            #TAG_MAP["$tag_slug"]+="$date|$title|$(basename "$post")|$desc_html"$'\n'
        done
        POST_BODY+="</div></article>"

        # Write post HTML
        slug=$(basename "$post")
        body_class="$slug"
        [[ -n "$section" ]] && body_class+=" $section"
        CRITICAL_CSS=$(tr -d '\n' < "$CRITICAL_CSS_FILE" | tr -s ' ')
        {
            awk -v css="$CRITICAL_CSS" -v title="$title - $SITE_TITLE" -v body_class="$body_class" \
                '{ gsub(/\{\{title\}\}/, title); gsub(/\{\{body_class\}\}/, body_class); gsub(/<!-- INLINE_CRITICAL_CSS -->/, "<style>" css "</style>"); print }' \
                "$TEMPLATES_DIR/header.html"
            echo "$POST_BODY"
            awk -v title="$SITE_TITLE" '{ gsub(/\{\{site_title\}\}/, title); print }' "$TEMPLATES_DIR/footer.html"
        } > "$post/index.html"

        #[[ "$hide_from_feed" == "0" ]] && POST_ENTRIES+=("$date|$title|$tags|$(basename "$post")|$desc_html|$section")

        echo "Built $post (hide_from_feed=$hide_from_feed photo_page=$photo_page)"

        # collect for tags and feeds
        IFS=',' read -ra tag_array <<< "$tags"
        for t in "${tag_array[@]}"; do
            clean_tag=$(trim "$t")
            [[ -z "$clean_tag" ]] && continue
            tag_slug=$(slugify "$clean_tag")
            TAG_DISPLAY["$tag_slug"]="$clean_tag"
            TAG_MAP["$tag_slug"]+="$date|$title|$(basename "$post")|$desc_html"$'\n'
        done
        #echo $desc_html
        
        #[[ "$hide_from_feed" == " 0" ]] || POST_ENTRIES+=("$date|$title|$tags|$(basename "$post")|$desc_html|$section")

        #[[ "$hide_from_feed" == " 1" ]] || POST_ENTRIES+=("$date"$'\t'"$title"$'\t'"$tags"$'\t'"$(basename "$post")"$'\t'"$description"$'\t'"$section")
        [[ "$hide_from_feed" == "1" ]] && continue
        POST_ENTRIES+=("$date|$title|$tags|$(basename "$post")|$desc_html|$section")
    done

    # Sort posts descending
    if [[ ${#POST_ENTRIES[@]} -gt 0 ]]; then
        IFS=$'\n' POST_ENTRIES=($(printf "%s\n" "${POST_ENTRIES[@]}" | sort -r))
        unset IFS
    fi

    # -----------------------------
    # BUILD INDEX
    # -----------------------------
    {
        CRITICAL_CSS=$(tr -d '\n' < "$CRITICAL_CSS_FILE" | tr -s ' ')
        awk -v css="$CRITICAL_CSS" -v title="$SITE_TITLE" -v body_class="index" \
            '{ gsub(/\{\{title\}\}/, title); gsub(/\{\{body_class\}\}/, body_class); gsub(/<!-- INLINE_CRITICAL_CSS -->/, "<style>" css "</style>"); print }' \
            "$TEMPLATES_DIR/header.html"

        echo '<h2 class="post-title">Home</h2>'
        echo "<ul class='postlist'>"

        for entry in "${POST_ENTRIES[@]}"; do
            
            IFS='|' read -r date title tags post_path desc_html section <<< "$entry"
            #IFS='|' read -r date title tags post_path section <<< "$entry"
            MD_FILE="$POSTS_DIR/$post_path/index.md"
            description=$(extract_description "$MD_FILE")
            desc_html=$(render_markdown "$description")           
            IFS=',' read -ra tag_array <<< "$tags"
            
            echo "<li class='post-item'>
                <div class='post-date'><time>$date</time></div>
                <div class='post-content'>
                    <h3 class='post-title'><a href='/$POSTS_DIR/$post_path'>$title</a></h3>
                    <div class='post-description'>$desc_html</div>
                    <div class='post-tags'>"

            IFS=',' read -ra tag_array <<< "$tags"
            for t in "${tag_array[@]}"; do
                clean_tag=$(trim "$t")
                [[ -z "$clean_tag" ]] && continue
                tag_slug=$(slugify "$clean_tag")
                echo "<a href='/$TAGS_DIR/${tag_slug}/' class='tag'>$clean_tag</a> "
            done

            echo "</div></div></li>"
        done

        echo "</ul>"

        awk -v title="$SITE_TITLE" '{ gsub(/\{\{site_title\}\}/, title); print }' "$TEMPLATES_DIR/footer.html"
    } > "$INDEX_FILE"
    echo "Generated $INDEX_FILE"


    # --- Build tag pages ---
    for tag_slug in "${!TAG_DISPLAY[@]}"; do
        tag_dir="$TAGS_DIR/$tag_slug"
        mkdir -p "$tag_dir"
        display_tag="${TAG_DISPLAY[$tag_slug]}"

        {
            CRITICAL_CSS=$(tr -d '\n' < "$CRITICAL_CSS_FILE" | tr -s ' ')
            awk -v css="$CRITICAL_CSS" -v title="Tag: $display_tag - $SITE_TITLE" -v body_class="tag-${tag_slug}" \
                '{ gsub(/\{\{title\}\}/, title); gsub(/\{\{body_class\}\}/, body_class); gsub(/<!-- INLINE_CRITICAL_CSS -->/, "<style>" css "</style>"); print }' \
                "$TEMPLATES_DIR/header.html"

            echo "<h2 class='post-title'>Tag: $display_tag</h2><ul class='postlist'>"

            IFS=$'\n' sorted=($(printf "%s\n" "${TAG_MAP[$tag_slug]}" | sort -r))
            unset IFS

            for line in "${sorted[@]}"; do
                IFS='|' read -r date title post_path desc_html <<< "$line"
                [[ -z "$date" ]] && continue

                echo "<li class='post-item'>
                    <div class='post-date'><time>$date</time></div>
                    <div class='post-content'>
                        <h3 class='post-title'><a href='/$POSTS_DIR/$post_path'>$title</a></h3>
                        <div class='post-description'>$desc_html</div>
                    </div>
                </li>"
            done

            echo "</ul>"
            awk -v title="$SITE_TITLE" '{ gsub(/\{\{site_title\}\}/, title); print }' "$TEMPLATES_DIR/footer.html"
        } > "$tag_dir/index.html"
    done


    # --- Build tag index (/tags/index.html) ---
    {
        CRITICAL_CSS=$(tr -d '\n' < "$CRITICAL_CSS_FILE" | tr -s ' ')
        awk -v css="$CRITICAL_CSS" -v title="Tags - $SITE_TITLE" -v body_class="tags-index" \
            '{ gsub(/\{\{title\}\}/, title); gsub(/\{\{body_class\}\}/, body_class); gsub(/<!-- INLINE_CRITICAL_CSS -->/, "<style>" css "</style>"); print }' \
            "$TEMPLATES_DIR/header.html"

        echo "<h2>Tags</h2><ul class='postlist tagslist'>"

        printf "%s\n" "${!TAG_MAP[@]}" | sort | while IFS= read -r tag_slug; do
            display_tag="${TAG_DISPLAY[$tag_slug]}"
            echo "<li><a href='/$TAGS_DIR/${tag_slug}/'>$display_tag</a></li>"
        done

        echo "</ul>"
        awk -v title="$SITE_TITLE" '{ gsub(/\{\{site_title\}\}/, title); print }' "$TEMPLATES_DIR/footer.html"
    } > "$TAGS_DIR/index.html"

    # --- Generate feeds (RSS + JSON) ---
    mkdir -p "$FEED_DIR"

    # RSS feed
    {
      echo "<?xml version='1.0' encoding='UTF-8'?>"
      echo "<rss version='2.0'>"
      echo "<channel>"
      echo "<title>$SITE_TITLE</title>"
      echo "<link>$BASE_URL</link>"
      echo "<description>Latest posts</description>"

      for entry in "${POST_ENTRIES[@]}"; do
        IFS='|' read -r date title tags post_path section <<< "$entry"

        # Extract content between markers
        content=$(awk '/<!-- POST_START -->/{flag=1; next} /<!-- POST_END -->/{flag=0} flag{print}' "$POSTS_DIR/$post_path/index.html" 2>/dev/null || true)

        safe_content="${content//]]>/]]]]><![CDATA[>}"

        # deterministic hash-based time
        hash=$(echo -n "$post_path" | md5sum | cut -c1-8)
        hour=$(( 0x${hash:0:2} % 24 ))
        minute=$(( 0x${hash:2:2} % 60 ))
        second=$(( 0x${hash:4:2} % 60 ))

        pubdate=$(format_rfc2822 "$date $hour:$minute:$second")

        echo "  <item>"
        echo "    <title><![CDATA[$title]]></title>"
        echo "    <link>$BASE_URL/$POSTS_DIR/$post_path</link>"
        echo "    <guid>$BASE_URL/$POSTS_DIR/$post_path</guid>"
        echo "    <pubDate>$pubdate</pubDate>"

        if [[ -n "$tags" ]]; then
          IFS=',' read -ra _tagarr <<< "$tags"
          for t in "${_tagarr[@]}"; do
            t_trimmed=$(trim "$t")
            [[ -n "$t_trimmed" ]] && echo "    <category><![CDATA[$t_trimmed]]></category>"
          done
        fi

        echo "    <description><![CDATA[$safe_content]]></description>"
        echo "  </item>"
      done

      echo "</channel>"
      echo "</rss>"
    } > "$FEED_DIR/feed.xml"

    # JSON feed
    {
      echo "["
      first=1
      for entry in "${POST_ENTRIES[@]}"; do
        IFS='|' read -r date title tags post_path section <<< "$entry"

        raw_content=$(awk '/<!-- POST_START -->/{flag=1; next} /<!-- POST_END -->/{flag=0} flag{print}' "$POSTS_DIR/$post_path/index.html" 2>/dev/null || true)
        json_content=$(printf "%s" "$raw_content" | perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\r?\n/\\n/g')

        tags_json=""
        if [[ -n "$tags" ]]; then
          IFS=',' read -ra _tagarr <<< "$tags"
          for t in "${_tagarr[@]}"; do
            t_trimmed=$(trim "$t")
            if [[ -n "$t_trimmed" ]]; then
              tags_json="$tags_json\"$t_trimmed\","
            fi
          done
          tags_json="[${tags_json%,}]"
        else
          tags_json="[]"
        fi

        hash=$(echo -n "$post_path" | md5sum | cut -c1-8)
        hour=$(( 0x${hash:0:2} % 24 ))
        minute=$(( 0x${hash:2:2} % 60 ))
        second=$(( 0x${hash:4:2} % 60 ))

        pubdate=$(format_rfc2822 "$date $hour:$minute:$second")

        [[ $first -eq 0 ]] && echo ","
        echo "  {"
        echo "    \"title\": \"$(printf '%s' "$title" | sed 's/\"/\\\"/g')\","
        echo "    \"link\": \"/$POSTS_DIR/$post_path\","
        echo "    \"date\": \"$pubdate\","
        echo "    \"tags\": $tags_json,"
        echo "    \"content\": \"$json_content\""
        echo "  }"
        first=0
      done
      echo "]"
    } > "$FEED_DIR/feed.json"

    echo "Feeds generated: $FEED_DIR/feed.xml and $FEED_DIR/feed.json"

    # --- Generate sitemap ---
    sitemap_file="sitemap.xml"
    base="${BASE_URL%/}"
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
      # homepage
      echo "  <url>"
      echo "    <loc>$base/</loc>"
      echo "    <lastmod>$(date +%Y-%m-%d)</lastmod>"
      echo "  </url>"

      # posts
      for entry in "${POST_ENTRIES[@]}"; do
        IFS='|' read -r date title tags post_path section <<< "$entry"
        echo "  <url>"
        echo "    <loc>$base/$POSTS_DIR/$post_path</loc>"
        echo "    <lastmod>$date</lastmod>"
        echo "  </url>"
      done

      # tags
      for tag_slug in "${!TAG_DISPLAY[@]}"; do
        echo "  <url>"
        echo "    <loc>$base/$TAGS_DIR/$tag_slug/</loc>"
        echo "    <lastmod>$(date +%Y-%m-%d)</lastmod>"
        echo "  </url>"
      done

      echo '</urlset>'
    } > "$sitemap_file"
    echo "Created $sitemap_file"

    echo "Build complete."
}

# -----------------------------
# INIT (create config, templates, css, scaffold Hello World, build)
# -----------------------------
init_project() {
    # refuse to init over existing project
    if [[ -d templates || -d css || -d posts ]]; then
        echo "Error: init cannot be run on an existing project."
        exit 1
    fi

    echo
    echo "Now let’s configure your project."

    read -p "Posts directory [posts]: " POSTS_DIR
    POSTS_DIR=${POSTS_DIR:-posts}

    read -p "Templates directory [templates]: " TEMPLATES_DIR
    TEMPLATES_DIR=${TEMPLATES_DIR:-templates}

    read -p "Feed directory [feeds]: " FEED_DIR
    FEED_DIR=${FEED_DIR:-feeds}

    read -p "Tags directory [tags]: " TAGS_DIR
    TAGS_DIR=${TAGS_DIR:-tags}

    read -p "Critical CSS file [css/critical.css]: " CRITICAL_CSS_FILE
    CRITICAL_CSS_FILE=${CRITICAL_CSS_FILE:-css/critical.css}

    read -p "Index file [index.html]: " INDEX_FILE
    INDEX_FILE=${INDEX_FILE:-index.html}

    read -p "Site title [Site Title]: " SITE_TITLE
    SITE_TITLE=${SITE_TITLE:-Site Title}

    # Write config.yml
    cat > "$CONFIG_FILE" <<EOF
POSTS_DIR: $POSTS_DIR
TEMPLATES_DIR: $TEMPLATES_DIR
FEED_DIR: $FEED_DIR
TAGS_DIR: $TAGS_DIR
CRITICAL_CSS_FILE: $CRITICAL_CSS_FILE
INDEX_FILE: $INDEX_FILE
SITE_TITLE: $SITE_TITLE
BASE_URL: http://localhost:8000
EOF

    echo "Created $CONFIG_FILE"

    echo "Initializing project structure..."
    mkdir -p css "$POSTS_DIR" "$TEMPLATES_DIR" "$FEED_DIR" "$TAGS_DIR"

    # Base CSS
    cat > css/style.css <<EOF
body {
  font-family: sans-serif;
}
EOF
    echo "Created css/style.css"

    # Ensure critical CSS exists
    mkdir -p "$(dirname "$CRITICAL_CSS_FILE")"
    if [[ ! -f "$CRITICAL_CSS_FILE" ]]; then
        echo "/* critical css (generated) */" > "$CRITICAL_CSS_FILE"
        echo "Created $CRITICAL_CSS_FILE"
    fi

    # Templates (preserve original header/footer content)
    cat > "$TEMPLATES_DIR/header.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{title}}</title>
  <meta name="description" content="">
  <!-- INLINE_CRITICAL_CSS -->
  <link rel="stylesheet" href="/css/style.min.css">
  <link rel="alternate" href="/feed/feed.xml" type="application/atom+xml" title="$SITE_TITLE rss feed">
  <link rel="alternate" href="/feed/feed.json" type="application/json" title="$SITE_TITLE json feed">
</head>
<body class="{{body_class}}">
<a href="#skip" class="visually-hidden">Skip to main content</a>
<header>
  <h1><a href="/" class="home-link" title="$SITE_TITLE">$SITE_TITLE</a></h1>
        <nav>
            <h2 class="visually-hidden">Top level navigation menu</h2>
            <ul class="nav">
                <li class="nav-item">
                    <a href="/" aria-current="page">Home</a>
                </li>
                <li class="nav-item">
                    <a href="/$FEED_DIR/feed.xml">RSS</a>
                </li>                              
            </ul>
        </nav>  
</header>
    <div class="page">
    <main id="skip">
        <section class="main">
        <!-- POST_START -->
EOF
    echo "Created $TEMPLATES_DIR/header.html"

    cat > "$TEMPLATES_DIR/footer.html" <<EOF
    <!-- POST_END -->
  <!--POSTNAV--></section>    
</main>
</div>
<footer>
  <p class="copyright">&copy; $(date +%Y) $SITE_TITLE</p>
</footer>
</body>
</html>
EOF
    echo "Created $TEMPLATES_DIR/footer.html"

    # Create an example Hello World post (markdown)
    mkdir -p "$POSTS_DIR/hello-world"
    POST_DATE=$(date +%Y-%m-%d)
    cat > "$POSTS_DIR/hello-world/index.md" <<EOF
---
title: Hello World
description: My first post on $SITE_TITLE
date: $POST_DATE
tags: intro, example
section: blog
hide_from_feed: 0
photo_page: 0
---

Welcome to your new site! 🎉

This is your very first post. You can edit or delete it, and create new ones with:

\`\`\`
$0 scaffold "My New Post"
\`\`\`
EOF

    echo "Created example post at $POSTS_DIR/hello-world/index.md"

    # Now run a build (use the build_site function in this script)
    echo "Bootstrapping site (running initial build)..."
    build_site

    echo "Project initialized."
}

# -----------------------------
# CLI Dispatch
# -----------------------------
case "$1" in
    init)
        init_project
        ;;
    scaffold)
        shift
        scaffold_post "$@"
        ;;
    build)
        build_site
        ;;
    *)
        echo "Usage: $0 {init|scaffold <title>|build}"
        exit 1
        ;;
esac

