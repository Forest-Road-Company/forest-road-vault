This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

Production builds require Vercel's 40-character `VERCEL_GIT_COMMIT_SHA`. After promoting a
deployment, bind the served site to the exact reviewed commit:

```bash
node tools/verify-frontend-revision.mjs \
  --url https://forestroadvault.com \
  --commit <40-character-final-commit>
```

The production project also requires `CRON_SECRET`, the daily schedule in `vercel.json`, and a
fixed-window WAF rule on `POST /api/curators/interest` allowing at most 16 requests per source IP
per 600 seconds. The application-level Blob gates remain a second layer and the cron deletes only
expired `curators-rate/` gate objects.
