package org.jspecify.annotations;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.CLASS)
@Target({
    ElementType.TYPE_USE,
    ElementType.TYPE_PARAMETER,
    ElementType.METHOD,
    ElementType.PARAMETER,
    ElementType.FIELD,
    ElementType.LOCAL_VARIABLE,
    ElementType.ANNOTATION_TYPE
})
public @interface Nullable {
}
