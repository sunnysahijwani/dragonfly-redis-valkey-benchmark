<?php
// Render the blog Markdown to HTML using the SITE'S OWN renderer (League
// CommonMark + TableExtension), so the output is byte-identical to what
// two-techies produces on save. In-body image paths are rewritten to the
// site's public path. Output: blog/html/*.html
require '/Applications/XAMPP/xamppfiles/htdocs/two-techies/new-two-techies-laravel/vendor/autoload.php';

use App\Services\MarkdownRenderer;

$blog   = '/Applications/XAMPP/xamppfiles/htdocs/dragonfly-benchmark/blog';
$out    = "$blog/html";
$imgUrl = '/assets/images/blog/dragonfly-benchmark/';   // where the PNGs get copied on the site
@mkdir($out, 0755, true);

$renderer = new MarkdownRenderer();

foreach (glob("$blog/*.md") as $md) {
    $name = basename($md, '.md');
    if ($name === 'PUBLISHING-PLAN' || $name === '00-linkedin-anchor') {
        continue; // not blog posts
    }
    $src  = file_get_contents($md);
    // rewrite relative image links -> site public path, and cross-post .md links -> /blog/<slug>
    $src  = str_replace('](images/', "]($imgUrl", $src);
    $src  = preg_replace('/\]\((\d\d)-[a-z0-9-]+\.md\)/i', '](/blog/PART-$1)', $src); // placeholder slugs
    $html = $renderer->toHtml($src);
    file_put_contents("$out/$name.html", $html);
    echo "wrote html/$name.html (" . strlen($html) . " bytes)\n";
}
echo "done\n";
