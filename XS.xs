/* ex: set sw=4 et: */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "devel_stacktrace_xs.h"

#define SAVE_ERR 0x01
#define SAVE_ARGS 0x02
#define SAVE_CV 0x04
#define SAVE_EVAL_TEXT 0x08
#define SAVE_MASK 0x0f

#define STRINGIFY_ARGS 0x10
#define RESPECT_OVERLOAD_ARGS 0x20

#define STRINGIFY_ERR 0x40
#define RESPECT_OVERLOAD_ERR 0x80

#define SEPARATE_HASARGS

/* this data can be just freed without refcounting */
/* the struct definitions are only syntactically compatible with PERL_CONTEXT */
struct frame {
    I32 offset;
    union {
        struct {
            U8   blku_type;
            U8   blku_gimme;
            COP *blku_oldcop;
#ifdef SEPARATE_HASARGS
            union {
                struct {
                    U8 hasargs;
                } blku_sub;
                struct {
                    U16 old_op_type;
                } blku_eval;
            } blk_u;
#endif
        } cx_blk;
        struct {
            U8 sbu_type; /* what kind of context this is */
        } cx_subst;
    } cx_u;
};

struct frames_info {
    I32 flags;
    I32 count;
    struct frame *frames;
    AV *refcounted;
};

STATIC int free_trace_magic(pTHX_ SV *sv, MAGIC *mg) {
    struct frames_info *f = (struct frames_info *)mg->mg_ptr;
    if ( f ) {
        SvREFCNT_dec(f->refcounted);

        Safefree(f->frames);
        Safefree(f);
        mg->mg_ptr = NULL;

    }
}

STATIC MGVTBL trace_vtbl = {
    NULL,            /* get */
    NULL,            /* set */
    NULL,            /* len */
    NULL,            /* clear */
    free_trace_magic, /* free */
#if MGf_COPY
    NULL,            /* copy */
#endif /* MGf_COPY */
#if MGf_DUP
    NULL,            /* dup */
#endif /* MGf_DUP */
#if MGf_LOCAL
    NULL,            /* local */
#endif /* MGf_LOCAL */
};

/* stolen from pp_ctl.c */
STATIC I32
dopoptosub_at(pTHX_ const PERL_CONTEXT *cxstk, I32 startingblock)
{
    dVAR;
    I32 i;

    for (i = startingblock; i >= 0; i--) {
        register const PERL_CONTEXT * const cx = &cxstk[i];
        switch (CxTYPE(cx)) {
            default:
                continue;
            case CXt_EVAL:
            case CXt_SUB:
            case CXt_FORMAT:
                return i;
        }
    }
    return i;
}

/* stringify is a macro... */
STATIC SV *
plz_stringify (SV *sv, bool overload) {
    if ( !SvROK(sv) || overload ) {
        /* stringify normally */
        STRLEN len;
        char *ptr = SvPV(sv, len);
        return newSVpvn(ptr, len);
    } else {
        /* like overload::StrVal */
        SV *rv = SvRV(sv);

        if ( sv_isobject(sv) ) {
            return newSVpvf("%s=%s(0x%p)", sv_reftype(rv, TRUE), sv_reftype(rv, FALSE), rv);
        } else {
            return newSVpvf("%s(0x%p)", sv_reftype(rv, FALSE), rv);
        }
    }
}

STATIC struct frames_info *
build_trace (pTHX_ const I32 uplevel, const I32 flags) {
    dVAR;
    dSP;
    const I32 save_refs = ( flags & SAVE_MASK & ~SAVE_ERR );
    const I32 save_err  = ( flags & SAVE_ERR ) ? 1 : 0;
    const PERL_SI *top_si = PL_curstackinfo;
    const PERL_CONTEXT *ccstack = cxstack;
    const PERL_CONTEXT *cx;
    struct frame *frames;
    struct frame *f;
    I32 cxix, skip, count, i, j;
    struct frames_info *fi;
    AV *refcounted = NULL;

    cxix = dopoptosub_at(cxstack, cxstack_ix);

    count = 0-uplevel;

    /* figure out how many frames we need to track */
    for (;;) {
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            top_si = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopoptosub_at(ccstack, top_si->si_cxix);
        }

        if (cxix < 0)
            break;

        /* count frames which aren't &DB::sub */
        if (!PL_DBsub || !GvCV(PL_DBsub) || ccstack[cxix].blk_sub.cv != GvCV(PL_DBsub))
            count++;

        cxix = dopoptosub_at(ccstack, cxix - 1);
    }

    if ( count <= 0 )
        return NULL;

    Newxz(frames, count, struct frame); 

    if ( save_refs || save_err ) {
        refcounted = newAV();
        av_extend(refcounted, count + save_err); /* may not be enough but it's a start */

        if ( save_err ) {
            av_push(
                    refcounted,
                    flags & STRINGIFY_ERR
                    ? plz_stringify(ERRSV, flags & RESPECT_OVERLOAD_ERR)
                    : newSVsv(ERRSV)
                   );
        }
    }

    cxix = dopoptosub_at(cxstack, cxstack_ix);
    ccstack = cxstack;
    i = 0;
    skip = uplevel;

    for (;;) {
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            top_si = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopoptosub_at(ccstack, top_si->si_cxix);
        }

        if (cxix < 0)
            break;

        if (!PL_DBsub || !GvCV(PL_DBsub) || cx->blk_sub.cv != GvCV(PL_DBsub)) {
            if ( !skip ) {
                cx = &ccstack[cxix];
                f = &frames[i++];

                f->blk_oldcop = cx->blk_oldcop;
                f->cx_type = cx->cx_type; /* not CxTYPE, that's masked */
                f->blk_gimme = cx->blk_gimme;
#ifdef SEPARATE_HASARGS
                f->blk_sub.hasargs = cx->blk_sub.hasargs;
#endif                
                f->offset = 0;

                if ( save_refs ) {
                    f->offset = av_len(refcounted) + 1;

                    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT ) {
                        if ( save_refs & SAVE_ARGS && CxHASARGS(cx) ) {
                            AV * const ary = cx->blk_sub.argarray;
                            AV *args = newAV();

                            if ( flags & STRINGIFY_ARGS ) {
                                av_extend(args, av_len(ary));

                                for ( j = 0; j < av_len(ary); j++ ) {
                                    SV **p = av_fetch(ary, j, FALSE);
                                    SV *str = plz_stringify(*p, (flags & RESPECT_OVERLOAD_ARGS) );
                                    av_push(args, str);
                                }
                            } else {
                                AvREAL_off(args);
                                const I32 off = AvARRAY(ary) - AvALLOC(ary);

                                if (AvMAX(args) < AvFILLp(ary) + off)
                                    av_extend(args, AvFILLp(ary) + off);

                                Copy(AvALLOC(ary), AvARRAY(args), AvFILLp(ary) + 1 + off, SV*);
                                AvFILLp(args) = AvFILLp(ary) + off;
                            }

                            av_push(refcounted, (SV *)args);
                        }

                        if ( save_refs & SAVE_CV )
                            av_push(refcounted, (SV *)cx->blk_sub.cv);
                    } else if (CxTYPE(cx) == CXt_EVAL && save_refs & SAVE_EVAL_TEXT ) {
                        av_push(refcounted, newSVsv(cx->blk_eval.cur_text));
                    }
                }
            } else {
                skip--;
            }
        }

        cxix = dopoptosub_at(ccstack, cxix - 1);
    }

    Newx(fi, 1, struct frames_info);

    fi->frames = frames;
    fi->count = count;
    fi->flags = flags;
    fi->refcounted = refcounted;

    return fi;
}

STATIC void
add_trace (pTHX_ SV *rv, I32 uplevel, I32 flags ) {
    struct frames_info *fi =  build_trace(aTHX_ uplevel, flags);

    if ( !fi )
        return;

    sv_magicext(rv, (SV *)fi->refcounted, PERL_MAGIC_ext, &trace_vtbl, (char *)fi, 0 );
}

STATIC AV *
frame_to_caller (pTHX_ I32 i, struct frames_info *fi) {
    AV *av = newAV();
    struct frame *cx = &fi->frames[i];
    const char *stashname = CopSTASHPV(cx->blk_oldcop);
    I32 gimme;

    av_extend(av, 11);

    if (!stashname)
        av_push(av, &PL_sv_undef);
    else
        av_push(av, newSVpv(stashname, 0));

    av_push(av, newSVpv(OutCopFILE(cx->blk_oldcop), 0));
    av_push(av, newSViv((I32)CopLINE(cx->blk_oldcop)));

    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        int hasargs = (CxHASARGS(cx) && (fi->flags & SAVE_ARGS) ? 1 : 0 );
        CV *cv = (CV *)*av_fetch(fi->refcounted, cx->offset + hasargs, FALSE);

        GV * const cvgv = CvGV(cv);/* ccstack[cxix].blk_sub.cv */
        /* So is ccstack[dbcxix]. */
        if (isGV(cvgv)) {
            SV * const sv = newSV(0);
            gv_efullname3(sv, cvgv, NULL);
            av_push(av, sv);
            av_push(av, boolSV(CxHASARGS(cx)));
        }
        else {
            av_push(av, newSVpvs_flags("(unknown)", SVs_TEMP));
            av_push(av, boolSV(CxHASARGS(cx)));
        }
    }
    else {
        av_push(av, newSVpvs_flags("(eval)", SVs_TEMP));
        av_push(av, newSViv(0));
    }

    gimme = (I32)cx->blk_gimme;
    if (gimme == G_VOID)
        av_push(av, &PL_sv_undef);
    else
        av_push(av, boolSV((gimme & G_WANT) == G_ARRAY));
    if (CxTYPE(cx) == CXt_EVAL) {
        /* eval STRING */
        if (CxOLD_OP_TYPE(cx) == OP_ENTEREVAL) {
            av_push(av, *av_fetch(fi->refcounted, cx->offset, FALSE)); /* cx->blk_eval.cur_text */
            av_push(av, &PL_sv_no);
        }
        /* require */
        /*
        else if (cx->blk_eval.old_namesv) {
            mPUSHs(newSVsv(cx->blk_eval.old_namesv));
            av_push(av, &PL_sv_yes);
        }*/
        /* eval BLOCK (try blocks have old_namesv == 0) */
        else {
            av_push(av, &PL_sv_undef);
            av_push(av, &PL_sv_undef);
        }
    }
    else {
        av_push(av, &PL_sv_undef);
        av_push(av, &PL_sv_undef);
    }
    /* XXX only hints propagated via op_private are currently
     * visible (others are not easily accessible, since they
     * use the global PL_hints) */
    av_push(av, newSViv(CopHINTS_get(cx->blk_oldcop)));
    {
        SV * mask ;
        STRLEN * const old_warnings = cx->blk_oldcop->cop_warnings ;

        if  (old_warnings == pWARN_NONE ||
                (old_warnings == pWARN_STD && (PL_dowarn & G_WARN_ON) == 0))
            mask = newSVpvn(WARN_NONEstring, WARNsize) ;
        else if (old_warnings == pWARN_ALL ||
                  (old_warnings == pWARN_STD && PL_dowarn & G_WARN_ON)) {
            /* Get the bit mask for $warnings::Bits{all}, because
             * it could have been extended by warnings::register */
            SV **bits_all;
            HV * const bits = get_hv("warnings::Bits", 0);
            if (bits && (bits_all=hv_fetchs(bits, "all", FALSE))) {
                mask = newSVsv(*bits_all);
            }
            else {
                mask = newSVpvn(WARN_ALLstring, WARNsize) ;
            }
        }
        else
            mask = newSVpvn((char *) (old_warnings + 1), old_warnings[0]);
            av_push(av, mask);
    }

    av_push(av, cx->blk_oldcop->cop_hints_hash ?
          sv_2mortal(newRV_noinc(
                                 MUTABLE_SV(Perl_refcounted_he_chain_2hv(aTHX_
                                              cx->blk_oldcop->cop_hints_hash))))
          : &PL_sv_undef);

    return av;
}

MODULE = Devel::StackTrace::XS PACKAGE = Devel::StackTrace::XS::Guts
PROTOTYPES: DISABLE

void
add_trace (err, uplevel, flags)
        SV *err
        I32 uplevel
        I32 flags
        CODE:
                if ( SvROK(err) )
                        add_trace(aTHX_ SvRV(err), uplevel, flags);

void die (err)
        SV *err
        CODE:
                if ( SvROK(err) )
                        add_trace(aTHX_ SvRV(err), 0, 0xff);

                /* yuck, this should be better by 5.14 */
                SV *errsv = get_sv("@", GV_ADD);
                sv_setsv(errsv, err);
                croak(NULL);

MODULE = Devel::StackTrace::XS PACKAGE = Devel::StackTrace::XS
PROTOTYPES: DISABLE

void
_xs_record_caller_data (self, raw, flags)
        SV *self
        AV *raw
        I32 flags
    CODE:
        add_trace(aTHX_ (SV *)raw, 1, flags | SAVE_CV);


void
_build_raw (self, raw)
        SV *self
        AV *raw
    PPCODE:
        if (SvTYPE((SV *)raw) >= SVt_PVMG) {
            SV *sv = (SV *)raw;
            MAGIC *mg;
            for (mg = SvMAGIC(sv); mg; mg = mg->mg_moremagic) {
                if (
                        (mg->mg_type == PERL_MAGIC_ext)
                        &&
                        (mg->mg_virtual == &trace_vtbl)
                   ) {
                    struct frames_info *fi = (struct frames_info *)mg->mg_ptr;
                    I32 i;

                    EXTEND(SP, fi->count);
                    for ( i = 0; i < fi->count; i++ ) {
                        AV *caller = frame_to_caller(i, fi);
                        AV *args = newAV();

                        HV *hv = newHV();
                        hv_stores(hv, "args", newRV_noinc((SV *)args));
                        hv_stores(hv, "caller", newRV_noinc((SV *)caller));
                        ST(i) = newRV_noinc((SV *)hv);
                    }

                    XSRETURN(fi->count);
                }
            }
        }
